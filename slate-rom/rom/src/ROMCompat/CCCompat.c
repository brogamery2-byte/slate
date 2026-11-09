
#include <sys/types.h>
#include <sys/sysctl.h>
#include <stddef.h>

int CCGetMaximumPerformanceCores(void)
{
    int count = 0; size_t size = sizeof(count);
    if(sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, NULL, 0) == 0 && count > 0)
    {
        return count;
    }
    count = 0; size = sizeof(count);
    if(sysctlbyname("hw.physicalcpu", &count, &size, NULL, 0) == 0 && count > 0)
    {
        return count;
    }
    return 1;
}
