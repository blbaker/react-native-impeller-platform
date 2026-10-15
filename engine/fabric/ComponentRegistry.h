#pragma once

// The host components Fabric can mount here, one descriptor provider each.
// FabricHost hands this to Fabric; the FP-52 props/scene fuzzers build props
// through the SAME descriptors, so a fuzzed prop map is parsed exactly as a
// React commit would parse it.

#include <memory>

namespace facebook::react {
class ComponentDescriptorProviderRegistry;
}

namespace rni {

std::shared_ptr<const facebook::react::ComponentDescriptorProviderRegistry>
MakeComponentProviderRegistry();

}  // namespace rni
