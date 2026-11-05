// The one piece of the core the shell asks about directly, for the UI-only
// simulator build in ios/uitest.
#pragma once

namespace xe {
namespace memory {
struct JitSignatureState {
  bool queried = true;
  bool get_task_allow = true;
  bool cs_debugged = true;
};
inline JitSignatureState QueryJitSignatureState() { return {}; }
}  // namespace memory
}  // namespace xe
