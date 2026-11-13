/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * See metal_pipeline_archive.h.
 ******************************************************************************
 */

#include "xenia/gpu/metal/metal_pipeline_archive.h"

#include <sys/sysctl.h>

#include <fstream>
#include <shared_mutex>
#include <sstream>
#include <system_error>

#include "xenia/base/logging.h"

namespace xe {
namespace gpu {
namespace metal {

namespace {

// Bump when what goes into a pipeline descriptor changes in a way the archive
// cannot see (it keys on functions and descriptor state, so this is rare).
constexpr uint32_t kSchemaVersion = 1;
// An archive past this is thrown away rather than loaded: it is mapped whole.
constexpr uintmax_t kMaxArchiveBytes = uintmax_t(384) << 20;
// After this many failed additions the archive stays read-only for the run.
constexpr uint32_t kMaxAddFailures = 8;

// Serialization takes an exclusive lock; additions share it, so workers keep
// compiling in parallel and only a write stops them.
std::shared_mutex& ArchiveLock() {
  static std::shared_mutex lock;
  return lock;
}

std::string OsBuild() {
  char build[64] = {};
  size_t size = sizeof(build) - 1;
  if (sysctlbyname("kern.osversion", build, &size, nullptr, 0) != 0) {
    return "unknown";
  }
  return std::string(build);
}

std::string Fingerprint(MTL::Device* device) {
  std::ostringstream out;
  out << "schema=" << kSchemaVersion << "\n";
  out << "os=" << OsBuild() << "\n";
  out << "gpu="
      << (device && device->name() ? device->name()->utf8String() : "unknown")
      << "\n";
  return out.str();
}

NS::URL* FileUrl(const std::filesystem::path& path) {
  return NS::URL::fileURLWithPath(
      NS::String::string(path.string().c_str(), NS::UTF8StringEncoding));
}

std::string ErrorText(NS::Error* error) {
  if (!error || !error->localizedDescription()) {
    return "unknown error";
  }
  return error->localizedDescription()->utf8String();
}

}  // namespace

MetalPipelineArchive::~MetalPipelineArchive() { Close(); }

void MetalPipelineArchive::Open(MTL::Device* device,
                                const std::filesystem::path& dir) {
  Close();
  if (!device) {
    return;
  }
  NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
  OpenLocked(device, dir);
  pool->release();
}

void MetalPipelineArchive::OpenLocked(MTL::Device* device,
                                      const std::filesystem::path& dir) {
  std::unique_lock<std::shared_mutex> archive_lock(ArchiveLock());
  std::lock_guard<std::mutex> lock(mutex_);
  device_ = device;
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  archive_path_ = dir / "pipelines.binarchive";
  const std::filesystem::path meta_path = dir / "pipelines.meta";

  // The sidecar says which OS and GPU produced the archive. A different one
  // (an OS update, a restored backup) means every entry would miss.
  const std::string fingerprint = Fingerprint(device);
  std::string stored;
  {
    std::ifstream meta(meta_path, std::ios::binary);
    if (meta) {
      std::ostringstream contents;
      contents << meta.rdbuf();
      stored = contents.str();
    }
  }
  bool reuse = stored == fingerprint &&
               std::filesystem::exists(archive_path_, ec);
  if (reuse) {
    const uintmax_t bytes = std::filesystem::file_size(archive_path_, ec);
    if (ec || bytes == 0 || bytes > kMaxArchiveBytes) {
      reuse = false;
    }
  }
  if (!reuse) {
    if (std::filesystem::exists(archive_path_, ec)) {
      XELOGI("Metal pipeline archive: discarding stale archive ({})",
             stored.empty() ? "no sidecar" : "OS or GPU changed");
    }
    std::filesystem::remove(archive_path_, ec);
    std::ofstream meta(meta_path, std::ios::binary | std::ios::trunc);
    meta << fingerprint;
  }

  MTL::BinaryArchiveDescriptor* desc =
      MTL::BinaryArchiveDescriptor::alloc()->init();
  if (reuse) {
    desc->setUrl(FileUrl(archive_path_));
  }
  NS::Error* error = nullptr;
  archive_ = device_->newBinaryArchive(desc, &error);
  if (!archive_ && reuse) {
    // A corrupt or truncated file: start empty instead of going without.
    XELOGW("Metal pipeline archive: could not load ({}); starting empty",
           ErrorText(error));
    std::filesystem::remove(archive_path_, ec);
    desc->setUrl(nullptr);
    error = nullptr;
    archive_ = device_->newBinaryArchive(desc, &error);
  }
  desc->release();
  if (!archive_) {
    XELOGW("Metal pipeline archive: unavailable ({})", ErrorText(error));
    return;
  }
  archive_array_ = NS::Array::array(archive_)->retain();
  pending_additions_ = 0;
  add_failures_ = 0;
  last_serialize_ = std::chrono::steady_clock::now();
  hits_.store(0, std::memory_order_relaxed);
  misses_.store(0, std::memory_order_relaxed);
  XELOGI("Metal pipeline archive: {} {}", reuse ? "loaded" : "created",
         archive_path_.string());
}

void MetalPipelineArchive::Close() {
  std::unique_lock<std::shared_mutex> archive_lock(ArchiveLock());
  std::lock_guard<std::mutex> lock(mutex_);
  if (!archive_) {
    return;
  }
  if (pending_additions_) {
    SerializeLocked();
  }
  XELOGI("Metal pipeline archive: closed, {} hits, {} misses", hits(),
         misses());
  archive_array_->release();
  archive_array_ = nullptr;
  archive_->release();
  archive_ = nullptr;
}

MTL::RenderPipelineState* MetalPipelineArchive::CreateRenderPipelineState(
    MTL::Device* device, MTL::RenderPipelineDescriptor* desc,
    NS::Error** error) {
  std::shared_lock<std::shared_mutex> archive_lock(ArchiveLock());
  if (!archive_ || device != device_) {
    return device->newRenderPipelineState(desc, error);
  }
  desc->setBinaryArchives(archive_array_);

  // Archive only: a hit costs no compile at all, a miss fails at once.
  NS::Error* miss_error = nullptr;
  MTL::RenderPipelineState* pipeline = device_->newRenderPipelineState(
      desc, MTL::PipelineOptionFailOnBinaryArchiveMiss, nullptr, &miss_error);
  if (pipeline) {
    hits_.fetch_add(1, std::memory_order_relaxed);
    return pipeline;
  }
  misses_.fetch_add(1, std::memory_order_relaxed);

  // A miss: compile into the archive, then create, which now finds it there.
  // So a miss compiles once, not twice.
  bool added = false;
  bool may_add;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    may_add = add_failures_ < kMaxAddFailures;
  }
  if (may_add) {
    NS::Error* add_error = nullptr;
    added = archive_->addRenderPipelineFunctions(desc, &add_error);
    std::lock_guard<std::mutex> lock(mutex_);
    if (added) {
      ++pending_additions_;
    } else if (++add_failures_ == kMaxAddFailures) {
      XELOGW("Metal pipeline archive: additions keep failing ({}); read-only "
             "for this run",
             ErrorText(add_error));
    }
  }
  pipeline = device_->newRenderPipelineState(desc, error);
  return pipeline;
}

void MetalPipelineArchive::MaybeSerialize() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!archive_ || !pending_additions_) {
      return;
    }
    const auto since = std::chrono::steady_clock::now() - last_serialize_;
    // Many new pipelines arrive together (a level load); write once they
    // settle rather than per pipeline. A trickle still lands within a minute.
    const bool due = (pending_additions_ >= 16 &&
                      since >= std::chrono::seconds(15)) ||
                     since >= std::chrono::seconds(60);
    if (!due) {
      return;
    }
  }
  std::unique_lock<std::shared_mutex> archive_lock(ArchiveLock());
  std::lock_guard<std::mutex> lock(mutex_);
  if (archive_ && pending_additions_) {
    SerializeLocked();
  }
}

void MetalPipelineArchive::SerializeLocked() {
  NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
  SerializeInPool();
  pool->release();
}

void MetalPipelineArchive::SerializeInPool() {
  // Written beside and renamed over, so a kill mid-write leaves the old file.
  std::filesystem::path temp = archive_path_;
  temp += ".tmp";
  std::error_code ec;
  std::filesystem::remove(temp, ec);
  NS::Error* error = nullptr;
  const auto start = std::chrono::steady_clock::now();
  if (!archive_->serializeToURL(FileUrl(temp), &error)) {
    XELOGW("Metal pipeline archive: serialize failed ({})", ErrorText(error));
    std::filesystem::remove(temp, ec);
    last_serialize_ = std::chrono::steady_clock::now();
    return;
  }
  std::filesystem::rename(temp, archive_path_, ec);
  if (ec) {
    XELOGW("Metal pipeline archive: rename failed ({})", ec.message());
    std::filesystem::remove(temp, ec);
  }
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - start)
                      .count();
  XELOGI("Metal pipeline archive: wrote {} new pipelines in {} ms ({} hits, "
         "{} misses so far)",
         pending_additions_, ms, hits(), misses());
  pending_additions_ = 0;
  last_serialize_ = std::chrono::steady_clock::now();
}

}  // namespace metal
}  // namespace gpu
}  // namespace xe
