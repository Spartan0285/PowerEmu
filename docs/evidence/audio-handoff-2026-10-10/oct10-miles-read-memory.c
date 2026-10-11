/* Diagnostic setup only. No task suspension, writes, privileges or audio client. */
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
int main(int argc, char **argv) {
    char *end; unsigned long pid, address, length; kern_return_t kr;
    mach_port_t task; vm_size_t actual = 0; unsigned char *bytes;
    if (argc != 4) { fprintf(stderr,"usage: read-memory PID HEX_ADDRESS HEX_LENGTH\n"); return 2; }
    errno=0; pid=strtoul(argv[1],&end,10);
    if(errno || *end || pid<2 || pid>INT_MAX) return 2;
    errno=0; address=strtoul(argv[2],&end,16);
    if(errno || *end || address<4096 || address>0xffffffffUL) return 2;
    errno=0; length=strtoul(argv[3],&end,16);
    if(errno || *end || !length || length>65536 || address+length<address || address+length>0xffffffffUL) return 2;
    bytes=malloc(length); if(!bytes) return 3;
    kr=task_for_pid(mach_task_self(),(int)pid,&task);
    if(kr!=KERN_SUCCESS) { fprintf(stderr,"task_for_pid: %s\n",mach_error_string(kr)); free(bytes); return 4; }
    kr=vm_read_overwrite(task,(vm_address_t)address,(vm_size_t)length,(vm_address_t)bytes,&actual);
    mach_port_deallocate(mach_task_self(),task);
    if(kr!=KERN_SUCCESS || actual!=length) { fprintf(stderr,"vm_read_overwrite: %s, actual=%lu\n",mach_error_string(kr),(unsigned long)actual); free(bytes); return 5; }
    if(fwrite(bytes,1,length,stdout)!=length || fflush(stdout)) { free(bytes); return 6; }
    free(bytes); return 0;
}
