/**
 ******************************************************************************
 * Xenra : iOS native driver                                                  *
 ******************************************************************************
 *
 * See ios_emu.h. This is the iOS counterpart of the Android layer in
 * emulator-core/src/main/cpp/xendroid_emu.cpp; the shapes deliberately match
 * (ticket-based synchronous CallInUIThread, fire-and-forget paint request,
 * boot thread driving Emulator::Setup -> SetupSubsystems -> LaunchPath) so
 * behaviour proven on Android transfers.
 */

#import <UIKit/UIKit.h>

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "ios_emu.h"
#include "XenraAudio.h"

#include "xenia/apu/nop/nop_audio_system.h"
#include "xenia/base/assert.h"
#include "xenia/base/clock.h"
#include "xenia/base/cvar.h"
#include "xenia/base/logging.h"
#include "xenia/base/frame_stats.h"
#include "xenia/base/memory.h"
#include "xenia/base/profiling.h"
#include "xenia/base/threading.h"
#include "xenia/config.h"
#include "xenia/cpu/processor.h"
#include "xenia/emulator.h"
#include "xenia/gpu/graphics_system.h"
#include "xenia/gpu/metal/metal_graphics_system.h"
#include "xenia/gpu/null/null_graphics_system.h"
#include "xenia/hid/input.h"
#include "xenia/hid/input_system.h"
#include "xenia/hid/nop/nop_input_driver.h"
#include "xenia/kernel/kernel_state.h"
#include "xenia/memory.h"
#include "xenia/ui/imgui_drawer.h"
#include "xenia/ui/immediate_drawer.h"
#include "xenia/ui/file_picker.h"
#include "xenia/ui/menu_item.h"
#include "xenia/ui/presenter.h"
#include "xenia/ui/surface_ios.h"
#include "xenia/ui/window.h"
#include "xenia/ui/windowed_app_context.h"
#include "xenia/vfs/devices/host_path_device.h"
#include "xenia/vfs/virtual_file_system.h"

// Defined by xendroid_emu.cpp on Android (and by the desktop xenia_main.cc on
// platforms that build it - iOS does not build either), and read by the
// engine: emulator.cc records gpu/apu for backend-change detection, the APU
// worker and the render-target cache read the two flags. Defaults pick the
// backends the iOS shell actually provides.
DEFINE_string(apu, "nop", "Audio system. Use: [nop]", "APU");
DEFINE_string(gpu, "metal", "Graphics system. Use: [metal, null]", "GPU");
DECLARE_path(log_file);

DEFINE_bool(apu_aaudio_log_stats, false, "Log AAudio stats (Android only)",
            "APU");
DEFINE_bool(log_host_depth_fallback, false,
            "Log host depth render-target fallbacks", "GPU");

// Defined by xendroid_emu.cpp on Android; emulator.cc reads them on every
// platform that boots through the shared RelaunchTitle path, so the iOS build
// has to carry its own definitions. Defaults match the Android ones.
// NOTE: the cvar macros use RELATIVE namespaces - at global file scope these
// land in ::cvars, which is exactly where emulator.cc's (namespace xe) bare
// `cvars::mount_*` references resolve.
DEFINE_bool(mount_scratch, false, "Enable scratch mount", "Storage");
DEFINE_bool(mount_cache, false, "Enable cache mount", "Storage");
DEFINE_bool(mount_memory_unit, false, "Enable memory unit (MU) mount",
            "Storage");

// The X_STATUS_SUCCESS / X_ERROR_* macros expand to the bare typedef names,
// which live in xe:: - make them visible at file scope so the macros work in
// this TU's global-namespace classes.
using xe::X_RESULT;
using xe::X_STATUS;

// Defined in presenter.cc. Fire-and-forget request_paint needs a UI pump that
// the present thread cannot block on; the iOS pump (a CADisplayLink on the
// main runloop) has the same shape as Android's, so force the flag like
// xendroid_emu.cpp does, in case a stale config turned it off.
DECLARE_bool(host_present_from_non_ui_thread);

namespace {

using xe::Emulator;
using xe::ui::ImGuiDrawer;
using xe::ui::Presenter;
using xe::ui::Window;

// ---------------------------------------------------------------------------
// Globals. All set on the main thread in xe_ios_initialize and read-only
// afterwards (except the app's lifecycle fields, guarded as noted).
// ---------------------------------------------------------------------------

UIView* g_game_view = nullptr;
std::filesystem::path g_documents_dir;
std::filesystem::path g_caches_dir;

std::atomic<int> g_status{0};  // 0 idle, 1 booting, 2 running, <0 failed
std::string g_status_detail;

std::unique_ptr<class IosWindowedAppContext> g_context;
std::unique_ptr<Window> g_window;
std::unique_ptr<ImGuiDrawer> g_imgui_drawer;
std::unique_ptr<class IosEmuApp> g_app;

class IosWindowedAppContext final : public xe::ui::WindowedAppContext {
 public:
  // Pending-work flags, same shape as the Android context.
  static constexpr uint32_t kEventExecutePendingFunctions = 1u << 0;
  static constexpr uint32_t kEventQuit = 1u << 1;

  IosWindowedAppContext() {
    pthread_mutex_init(&mutex_, nullptr);
    pthread_cond_init(&cond_, nullptr);
  }
  ~IosWindowedAppContext() {
    pthread_cond_destroy(&cond_);
    pthread_mutex_destroy(&mutex_);
  }

  // Called from non-UI threads. Marshals to the main runloop, then waits for
  // the ticket to complete - the synchronous CallInUIThread contract boot
  // relies on (GraphicsSystem::Setup marshals surface work).
  void NotifyUILoopOfPendingFunctions() override {
    assert(WindowedAppContext::ui_thread_id_ != std::this_thread::get_id());
    dispatch_async(dispatch_get_main_queue(), ^{ xe_ios_pump(); });

    pthread_mutex_lock(&mutex_);
    uint64_t ticket = ++exec_requested_;
    pending_events_ |= kEventExecutePendingFunctions;
    while (exec_completed_ < ticket && !ui_loop_exited_) {
      pthread_cond_wait(&cond_, &mutex_);
    }
    pthread_mutex_unlock(&mutex_);
  }

  void PlatformQuitFromUIThread() override {
    pthread_mutex_lock(&mutex_);
    pending_events_ |= kEventQuit;
    pthread_mutex_unlock(&mutex_);
    // The shell tears the app down synchronously from the main thread, so
    // there is no long-lived loop to wake here; xe_ios_pump handles the rest.
    dispatch_async(dispatch_get_main_queue(), ^{ xe_ios_pump(); });
  }

  // Main thread only.
  void PumpFromUIThread() {
    pthread_mutex_lock(&mutex_);
    uint32_t events = pending_events_;
    pending_events_ &= ~(kEventExecutePendingFunctions | kEventQuit);
    uint64_t exec_to = exec_requested_;
    pthread_mutex_unlock(&mutex_);

    if (events & kEventExecutePendingFunctions) {
      WindowedAppContext::ExecutePendingFunctionsFromUIThread();
      pthread_mutex_lock(&mutex_);
      exec_completed_ = exec_to;
      pthread_cond_broadcast(&cond_);
      pthread_mutex_unlock(&mutex_);
    }

    if (events & kEventQuit) {
      WindowedAppContext::QuitFromUIThread();
      pthread_mutex_lock(&mutex_);
      ui_loop_exited_ = true;
      exec_completed_ = exec_requested_;
      pthread_cond_broadcast(&cond_);
      pthread_mutex_unlock(&mutex_);
    }
  }

  void MarkUiLoopExitedFromUIThread() {
    pthread_mutex_lock(&mutex_);
    ui_loop_exited_ = true;
    exec_completed_ = exec_requested_;
    pthread_cond_broadcast(&cond_);
    pthread_mutex_unlock(&mutex_);
  }

 private:
  pthread_mutex_t mutex_;
  pthread_cond_t cond_;
  uint32_t pending_events_ = 0;
  uint64_t exec_requested_ = 0;
  uint64_t exec_completed_ = 0;
  bool ui_loop_exited_ = false;
};

// ---------------------------------------------------------------------------
// Window. Presents into the shell's CAMetalLayer-backed UIView.
// ---------------------------------------------------------------------------

class IosWindow final : public Window {
 public:
  IosWindow(xe::ui::WindowedAppContext& app_context,
            const std::string_view title, uint32_t desired_logical_width,
            uint32_t desired_logical_height)
      : Window(app_context, title, desired_logical_width,
               desired_logical_height) {}

 protected:
  bool OpenImpl() override { return true; }
  void RequestCloseImpl() override {}

  std::unique_ptr<xe::ui::Surface> CreateSurfaceImpl(
      xe::ui::Surface::TypeFlags allowed_types) override {
    if ((allowed_types & xe::ui::Surface::kTypeFlag_IosUIView) && g_game_view) {
      return std::make_unique<xe::ui::IosUIViewSurface>(g_game_view);
    }
    return nullptr;
  }

  void RequestPaintImpl() override {
    // Fire and forget: with host_present_from_non_ui_thread the present
    // thread lands here while holding the paint mutex - blocking would be
    // the AB-BA deadlock the Android layer documented. The display link
    // drives xe_ios_pump at frame rate, so the flag is consumed for free.
    // Painting is volume-driven from the pump; nothing else to do here.
  }

 public:
  void Paint() { OnPaint(false); }
};

}  // namespace

namespace xe {
namespace ui {

// Window::Create is defined per platform; the Android one lives in
// xendroid_emu.cpp, the wx one in windowed_app_wx.cc. iOS defines it here.
std::unique_ptr<Window> Window::Create(WindowedAppContext& app_context,
                                       const std::string_view title,
                                       uint32_t desired_logical_width,
                                       uint32_t desired_logical_height) {
  return std::make_unique<::IosWindow>(app_context, title,
                                       desired_logical_width,
                                       desired_logical_height);
}

// MenuItem::Create likewise has one definition per platform shell. The iOS
// shell has no native menu bar; games route their UI through ImGui dialogs.
std::unique_ptr<MenuItem> MenuItem::Create(Type type, const std::string& text,
                                           const std::string& hotkey,
                                           std::function<void()> callback) {
  class IosMenuItem final : public MenuItem {
   public:
    IosMenuItem(Type type, const std::string& text, const std::string& hotkey,
                std::function<void()> callback)
        : MenuItem(type, text, hotkey, std::move(callback)) {}
  };
  return std::make_unique<IosMenuItem>(type, text, hotkey, std::move(callback));
}

// FilePicker::Create likewise. Games' own "open file" flows (disc swap, icon
// changes) have no UIKit sheet wired up yet - report "cancelled", exactly as
// the Android stub does, while the shell's own import path is the Files app.
class IosFilePicker final : public FilePicker {
 public:
  bool Show(Window* parent_window) override { return false; }
};

std::unique_ptr<FilePicker> FilePicker::Create() {
  return std::make_unique<IosFilePicker>();
}

}  // namespace ui
}  // namespace xe

namespace {

// ---------------------------------------------------------------------------
// Input. One virtual gamepad fed by the UIKit touch overlay.
// ---------------------------------------------------------------------------

class IosInputDriver final : public xe::hid::InputDriver {
 public:
  IosInputDriver(Window* window, size_t window_z_order)
      : InputDriver(window, window_z_order) {}

  xe::X_STATUS Setup() override { return X_STATUS_SUCCESS; }

  xe::X_RESULT GetCapabilities(uint32_t user_index, uint32_t flags,
                           xe::hid::X_INPUT_CAPABILITIES* out_caps) override {
    if (user_index != 0) {
      return X_ERROR_DEVICE_NOT_CONNECTED;
    }
    std::memset(out_caps, 0, sizeof(*out_caps));
    out_caps->type = 0x01;      // XINPUT_DEVTYPE_GAMEPAD
    out_caps->sub_type = 0x01;  // XINPUT_DEVSUBTYPE_GAMEPAD
    out_caps->flags = 0;
    out_caps->gamepad.buttons = 0xF3FF;  // every button we can inject
    return X_ERROR_SUCCESS;
  }

  xe::X_RESULT GetState(uint32_t user_index, xe::hid::X_INPUT_STATE* out_state) override {
    if (user_index != 0) {
      return X_ERROR_DEVICE_NOT_CONNECTED;
    }
    uint32_t packet = packet_number_.load(std::memory_order_relaxed);
    xe::hid::X_INPUT_GAMEPAD gamepad;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      gamepad = gamepad_;
    }
    out_state->packet_number = packet;
    out_state->gamepad = gamepad;
    return X_ERROR_SUCCESS;
  }

  xe::X_RESULT SetState(uint32_t user_index,
                    xe::hid::X_INPUT_VIBRATION* vibration) override {
    // No rumble on iOS yet; report success so games do not warn.
    return X_ERROR_SUCCESS;
  }

  xe::X_RESULT GetKeystroke(uint32_t user_index, uint32_t flags,
                        xe::hid::X_INPUT_KEYSTROKE* out_keystroke) override {
    return X_ERROR_DEVICE_NOT_CONNECTED;
  }

  xe::hid::InputType GetInputType() const override {
    return xe::hid::InputType::Controller;
  }

  std::vector<xe::hid::InputDeviceInfo> EnumerateDevices() override {
    xe::hid::InputDeviceInfo info;
    info.driver_slot = 0;
    info.stable_id = "ios-virtual-gamepad";
    info.display_name = "On-screen controls";
    info.subtype = 0x01;
    info.preferred_slot = 0;
    info.auto_bind = true;
    return {info};
  }

  // Called from the main thread by xe_ios_input_set.
  void Update(uint16_t buttons, int16_t lx, int16_t ly, int16_t rx, int16_t ry,
              uint8_t lt, uint8_t rt) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      std::memset(&gamepad_, 0, sizeof(gamepad_));
      gamepad_.buttons = buttons;
      gamepad_.thumb_lx = lx;
      gamepad_.thumb_ly = ly;
      gamepad_.thumb_rx = rx;
      gamepad_.thumb_ry = ry;
      gamepad_.left_trigger = lt;
      gamepad_.right_trigger = rt;
    }
    packet_number_.fetch_add(1, std::memory_order_relaxed);
  }

 private:
  std::mutex mutex_;
  xe::hid::X_INPUT_GAMEPAD gamepad_{};
  std::atomic<uint32_t> packet_number_{0};
};

IosInputDriver* g_input_driver = nullptr;

// ---------------------------------------------------------------------------
// The app: owns the Emulator and the boot thread.
// ---------------------------------------------------------------------------

class IosEmuApp {
 public:
  IosEmuApp() = default;
  ~IosEmuApp() { StopEmuThread(); }

  Window& window() { return *g_window; }
  ImGuiDrawer& imgui_drawer() { return *g_imgui_drawer; }

  void Boot(const std::filesystem::path& path) {
    if (boot_started_.exchange(true)) {
      return;  // One boot per process on iOS; title relaunch needs a fresh
               // process for now.
    }
    g_status.store(1, std::memory_order_relaxed);
    g_status_detail = "booting";
    launch_path_ = path;
    emu_thread_ = std::thread(&IosEmuApp::EmuThreadMain, this);
  }

  void StopEmuThread() {
    if (emu_thread_.joinable()) {
      emu_thread_.join();
    }
  }

  // Main-thread painting setup, mirroring EmulatorWindow's
  // SetupGraphicsSystemPresenterPainting minus the profiler hooks.
  void SetupPresenterPaintingFromUIThread() {
    auto* graphics_system = emu_ ? emu_->graphics_system() : nullptr;
    Presenter* presenter = graphics_system ? graphics_system->presenter() : nullptr;
    if (!presenter) {
      return;
    }
    static_cast<IosWindow*>(g_window.get())->SetPresenter(presenter);
    immediate_drawer_ = graphics_system->provider()->CreateImmediateDrawer();
    if (immediate_drawer_) {
      immediate_drawer_->SetPresenter(presenter);
      g_imgui_drawer->SetPresenterAndImmediateDrawer(
          presenter, immediate_drawer_.get());
    }
  }

  void ShutdownPresenterPaintingFromUIThread() {
    g_imgui_drawer->SetPresenterAndImmediateDrawer(nullptr, nullptr);
    immediate_drawer_.reset();
    static_cast<IosWindow*>(g_window.get())->SetPresenter(nullptr);
  }

 private:
  static std::unique_ptr<xe::apu::AudioSystem> CreateAudioSystem(
      xe::cpu::Processor* processor) {
    return XenraCreateAudioSystem(processor);
  }

  static std::unique_ptr<xe::gpu::GraphicsSystem> CreateGraphicsSystem() {
    if (xe::gpu::metal::MetalGraphicsSystem::IsAvailable()) {
      return std::make_unique<xe::gpu::metal::MetalGraphicsSystem>();
    }
    return std::make_unique<xe::gpu::null::NullGraphicsSystem>();
  }

  static std::vector<std::unique_ptr<xe::hid::InputDriver>> CreateInputDrivers(
      xe::ui::Window* window) {
    std::vector<std::unique_ptr<xe::hid::InputDriver>> drivers;
    auto driver = std::make_unique<IosInputDriver>(window, 1);
    if (XSUCCEEDED(driver->Setup())) {
      g_input_driver = driver.get();
      drivers.emplace_back(std::move(driver));
    } else {
      g_input_driver = nullptr;
      drivers.emplace_back(
          std::make_unique<xe::hid::nop::NopInputDriver>(window, 1));
    }
    return drivers;
  }

  void EmuThreadMain() {
    xe::threading::set_name("Emulator");
    xe::Profiler::ThreadEnter("Emulator");

    xe::X_STATUS result = emu_->Setup(
        g_window.get(), g_imgui_drawer.get(), true, CreateAudioSystem,
        CreateGraphicsSystem, CreateInputDrivers);
    if (XFAILED(result)) {
      g_status.store(-1, std::memory_order_relaxed);
      g_status_detail = "emulator setup failed";
      XELOGE("iOS: emulator setup failed: {:08X}", result);
      return;
    }
    if (XFAILED(result = emu_->SetupSubsystems())) {
      g_status.store(-2, std::memory_order_relaxed);
      g_status_detail = "subsystem setup failed";
      XELOGE("iOS: subsystem setup failed: {:08X}", result);
      return;
    }

    MountDrives();

    emu_->on_before_shutdown.AddListener([this]() {
      g_context->CallInUIThreadSynchronous([this]() {
        ShutdownPresenterPaintingFromUIThread();
      });
    });
    emu_->on_launch.AddListener([this](auto title_id, const auto& game_title) {
      XELOGI("iOS: title launch {}", title_id);
      XELOGI("iOS: title name {}",
             game_title.empty() ? std::string("Unknown Title")
                                : std::string(game_title));
      g_context->CallInUIThread(
          [this]() { SetupPresenterPaintingFromUIThread(); });
      g_status.store(2, std::memory_order_relaxed);
      g_status_detail = "running";
    });

    result = emu_->LaunchPath(launch_path_);
    if (XFAILED(result)) {
      g_status.store(-3, std::memory_order_relaxed);
      g_status_detail = "title launch failed";
      XELOGE("iOS: title launch failed: {:08X}", result);
    }
  }

  void MountDrives() {
    auto* fs = emu_->file_system();
    if (cvars::mount_cache) {
      auto cache_device = std::make_unique<xe::vfs::HostPathDevice>(
          "\\CACHE", emu_->cache_root(), false);
      if (cache_device->Initialize() &&
          fs->RegisterDevice(std::move(cache_device))) {
        fs->RegisterSymbolicLink("cache:", "\\CACHE");
      }
    }
  }

 public:
  std::unique_ptr<Emulator> emu_;

 private:
  std::unique_ptr<xe::ui::ImmediateDrawer> immediate_drawer_;
  std::thread emu_thread_;
  std::atomic<bool> boot_started_{false};
  std::filesystem::path launch_path_;
};

}  // namespace

// ---------------------------------------------------------------------------
// The C API.
// ---------------------------------------------------------------------------

int xe_ios_initialize(const char* documents_dir, const char* caches_dir,
                      const char* log_path) {
  if (g_app) {
    return -1;
  }
  g_documents_dir = documents_dir;
  g_caches_dir = caches_dir;

  std::filesystem::create_directories(g_documents_dir / "config");
  std::filesystem::create_directories(g_documents_dir / "Games");
  std::filesystem::create_directories(g_documents_dir / "content");

  // Before InitializeLogging, which otherwise opens a file in the read-only app
  // bundle, fails, and logs nowhere without saying so.
  cvars::log_file = log_path;
  xe::InitializeLogging("xenra-ios");

  // The iOS pump never blocks the present thread (see IosWindow).
  cvars::host_present_from_non_ui_thread = true;

  config::SetupConfig(g_documents_dir);

  g_context = std::make_unique<IosWindowedAppContext>();
  // The context was constructed on this (main) thread, so ui_thread_id_ is
  // already right; assert it for the reader.
  assert_true(g_context->IsInUIThread());

  g_window = xe::ui::Window::Create(*g_context, "Xenra", 1280, 720);
  if (!g_window || !g_window->Open()) {
    g_status_detail = "window creation failed";
    return -2;
  }
  g_imgui_drawer =
      std::make_unique<ImGuiDrawer>(g_window.get(), 1);

  g_app = std::make_unique<IosEmuApp>();
  g_app->emu_ = std::make_unique<Emulator>(
      "", g_documents_dir, g_documents_dir / "content", g_caches_dir);
  return 0;
}

void xe_ios_flush_log(void) { xe::FlushLog(); }

void xe_ios_set_game_view(UIView* view) { g_game_view = view; }

void xe_ios_set_cvar(const char* name, const char* value) {
  auto it = cvar::ConfigVars->find(name);
  if (it == cvar::ConfigVars->end()) {
    XELOGW("iOS: no such setting: {}", name);
    return;
  }
  toml::table table = toml::parse(fmt::format("value = {}", value));
  it->second->LoadConfigValue(table.get("value"));
}

int xe_ios_boot(const char* path) {
  if (!g_app || !g_app->emu_) {
    return -1;
  }
  // CS_DEBUGGED is the kernel's own answer, asked fresh every time. Executing
  // generated code without it gets the process killed, not an error.
  if (!xe::memory::QueryJitSignatureState().cs_debugged) {
    g_status_detail = "JIT is OFF - enable it via StikDebug first";
    return -2;
  }
  g_app->Boot(path);
  return 0;
}

void xe_ios_pump(void) {
  if (g_context) {
    g_context->PumpFromUIThread();
  }
  if (g_window) {
    static_cast<::IosWindow*>(g_window.get())->Paint();
  }
}

void xe_ios_input_set(int buttons, short lx, short ly, short rx, short ry,
                      unsigned char lt, unsigned char rt) {
  if (g_input_driver) {
    g_input_driver->Update(static_cast<uint16_t>(buttons), lx, ly, rx, ry, lt,
                           rt);
  }
}

int xe_ios_status(void) { return g_status.load(std::memory_order_relaxed); }

const char* xe_ios_status_detail(void) { return g_status_detail.c_str(); }

void xe_ios_shutdown(void) {
  if (!g_app) {
    return;
  }
  if (g_app->emu_) {
    // Run the presenter teardown the on_before_shutdown listener would have
    // run, then stop the thread before tearing the emulator down.
    g_context->CallInUIThreadSynchronous([]() {
      if (g_app) {
        g_app->ShutdownPresenterPaintingFromUIThread();
      }
    });
  }
  g_app->StopEmuThread();
  if (g_app->emu_) {
    g_app->emu_->TerminateTitle();
    g_app->emu_->Shutdown();
  }
  g_app.reset();
  g_imgui_drawer.reset();
  g_window.reset();
  g_context->MarkUiLoopExitedFromUIThread();
  g_context.reset();
  g_input_driver = nullptr;
}

void xe_ios_set_paused(int paused) {
  if (!g_app || !g_app->emu_) return;
  if (paused) {
    g_app->emu_->Pause();
  } else {
    g_app->emu_->Resume();
  }
}

float xe_ios_fps(void) { return xe::GetHostPresentFps(); }
