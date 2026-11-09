#include <LindChain/ProcEnvironment/Surface/cache/shimcache.h>
#include <LindChain/ProcEnvironment/Surface/libkern/patch.h>
#include <LindChain/ProcEnvironment/Surface/libkern/klog.h>

LIBKERN_DEFINE_PATCHABLE(kern_return_t, ksurface_shimcache_append_code,
                         (CCFileType fileType, const char *code))
{
    (void)fileType;
    (void)code;
    klog_log("shimcache", "guest shim source ignored by ROM host");
    return KERN_SUCCESS;
}

LIBKERN_DEFINE_PATCHABLE(kern_return_t, ksurface_shimcache_build, (void))
{
    klog_log("shimcache", "no host-side compiler; shimcache build skipped");
    return KERN_SUCCESS;
}
