/* Unscored setup only: finite, read-only thread PC/LR/TOC sampling, no suspension. */
#include <mach/mach.h>
#include <mach/ppc/thread_status.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <pthread.h>
#include <sys/wait.h>
#include <stddef.h>
#include <stdint.h>
#include <mach/mach_time.h>
#include <CoreAudio/CoreAudio.h>
#define CAP 65536
struct record { unsigned round,thread,pc,lr,toc,sp,word,word_ok; unsigned r3,r4,r5,r6,r7,r8,r9,r24,r25,r26,r28,r30; uint64_t begin_ticks,end_ticks; };
static struct record records[CAP];
extern unsigned char pe_snapshot_loop[],pe_snapshot_loop_end[];
static void *register_worker(void *unused) {
 (void)unused;
 __asm__ volatile("li r3,0x103\nli r4,0x104\nli r5,0x105\nli r6,0x106\nli r7,0x107\nli r8,0x108\nli r9,0x109\nli r24,0x124\nli r25,0x125\nli r26,0x126\nli r28,0x128\nli r30,0x130\n.globl _pe_snapshot_loop\n_pe_snapshot_loop:\nb _pe_snapshot_loop\n.globl _pe_snapshot_loop_end\n_pe_snapshot_loop_end:\n");
 return 0;
}
static void report_abi(void) {
 mach_timebase_info_data_t tb={0,0}; kern_return_t kr=mach_timebase_info(&tb);
 printf("{\"AudioTimeStamp_size\":%lu,\"sampleTime_offset\":%lu,\"hostTime_offset\":%lu,\"rateScalar_offset\":%lu,\"wordClockTime_offset\":%lu,\"smpteTime_offset\":%lu,\"flags_offset\":%lu,\"reserved_offset\":%lu,\"timebase_status\":%d,\"timebase_numer\":%u,\"timebase_denom\":%u}\n",(unsigned long)sizeof(AudioTimeStamp),(unsigned long)offsetof(AudioTimeStamp,mSampleTime),(unsigned long)offsetof(AudioTimeStamp,mHostTime),(unsigned long)offsetof(AudioTimeStamp,mRateScalar),(unsigned long)offsetof(AudioTimeStamp,mWordClockTime),(unsigned long)offsetof(AudioTimeStamp,mSMPTETime),(unsigned long)offsetof(AudioTimeStamp,mFlags),(unsigned long)offsetof(AudioTimeStamp,mReserved),kr,tb.numer,tb.denom);
}
int main(int argc,char **argv) {
 char *end;unsigned long pid,low,high;mach_port_t task;unsigned n=0,round,errors=0,drops=0; kern_return_t kr;int selftest=0;pid_t child=-1;unsigned fixture_failures=0,round_limit=500,interval_us=10000;
 if(argc==2 && !strcmp(argv[1],"--abi")){report_abi();return 0;}
 if(argc==2 && (!strcmp(argv[1],"--self-test")||!strcmp(argv[1],"--self-test-fast"))){pthread_t worker;selftest=1;round_limit=10;if(!strcmp(argv[1],"--self-test-fast"))interval_us=1000;if(pthread_create(&worker,0,register_worker,0))return 5;usleep(100000);pid=getpid();low=(unsigned long)pe_snapshot_loop;high=(unsigned long)pe_snapshot_loop_end;goto parsed;}
 if(argc==5 && !strcmp(argv[1],"--fast")){round_limit=5000;interval_us=1000;argc--;argv++;}
 if(argc!=4) return 2;
 errno=0;pid=strtoul(argv[1],&end,10);if(errno||*end||pid<2||pid>INT_MAX)return 2;
 errno=0;low=strtoul(argv[2],&end,16);if(errno||*end||low<4096||low>0xffffffffUL)return 2;
 errno=0;high=strtoul(argv[3],&end,16);if(errno||*end||high<=low||high>0xffffffffUL||high-low>1024*1024)return 2;
parsed:
 if(selftest){task=mach_task_self();kr=KERN_SUCCESS;}else kr=task_for_pid(mach_task_self(),(int)pid,&task);if(kr!=KERN_SUCCESS){fprintf(stderr,"task_for_pid: %s\n",mach_error_string(kr));if(child>0){kill(child,SIGTERM);waitpid(child,0,0);}return 3;}
 for(round=0;round<round_limit;round++) {
  thread_act_array_t threads;mach_msg_type_number_t count=0,j;
  kr=task_threads(task,&threads,&count);if(kr!=KERN_SUCCESS){errors++;break;}
  if(count>1024){errors++;for(j=0;j<count;j++)mach_port_deallocate(mach_task_self(),threads[j]);vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));break;}
  for(j=0;j<count;j++) {
   uint64_t begin=mach_absolute_time(),finish;
   ppc_thread_state_t st;mach_msg_type_number_t sc=PPC_THREAD_STATE_COUNT;
   kr=thread_get_state(threads[j],PPC_THREAD_STATE,(thread_state_t)&st,&sc);
   finish=mach_absolute_time();
   if(kr!=KERN_SUCCESS||sc!=PPC_THREAD_STATE_COUNT)errors++;
   else if((st.srr0>=low&&st.srr0<high)||(st.lr>=low&&st.lr<high)){
    unsigned word=0,word_ok=0; vm_size_t actual=0;
    if(st.srr0>=low&&st.srr0<high){kr=vm_read_overwrite(task,st.srr0,4,(vm_address_t)&word,&actual);word_ok=(kr==KERN_SUCCESS&&actual==4);if(!word_ok)errors++;}
    if(n==CAP)drops++;else records[n++]=(struct record){round,(unsigned)threads[j],st.srr0,st.lr,st.r2,st.r1,word,word_ok,st.r3,st.r4,st.r5,st.r6,st.r7,st.r8,st.r9,st.r24,st.r25,st.r26,st.r28,st.r30,begin,finish};
   }
   mach_port_deallocate(mach_task_self(),threads[j]);
  }
  vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));
  usleep(interval_us);
 }
 if(!selftest)mach_port_deallocate(mach_task_self(),task);
 if(child>0){kill(child,SIGTERM);waitpid(child,0,0);}
 if(selftest){for(round=0;round<n;round++){struct record*r=&records[round];if(r->r3!=0x103||r->r4!=0x104||r->r5!=0x105||r->r6!=0x106||r->r7!=0x107||r->r8!=0x108||r->r9!=0x109||r->r24!=0x124||r->r25!=0x125||r->r26!=0x126||r->r28!=0x128||r->r30!=0x130||r->pc!=(unsigned)pe_snapshot_loop||r->word!=0x48000000||!r->word_ok)fixture_failures++;}if(!n)fixture_failures++;}
 printf("{\"pid\":%lu,\"range_low\":%lu,\"range_high\":%lu,\"rounds\":%u,\"errors\":%u,\"drops\":%u,\"configured_rounds\":%u,\"interval_us\":%u,\"selftest\":%s,\"fixture_failures\":%u,\"records\":[",pid,low,high,round,errors,drops,round_limit,interval_us,selftest?"true":"false",fixture_failures);
 for(round=0;round<n;round++){struct record *r=&records[round];printf("%s{\"round\":%u,\"thread\":%u,\"pc\":%u,\"lr\":%u,\"toc\":%u,\"sp\":%u,\"word\":%u,\"word_ok\":%u,\"r3\":%u,\"r4\":%u,\"r5\":%u,\"r6\":%u,\"r7\":%u,\"r8\":%u,\"r9\":%u,\"r24\":%u,\"r25\":%u,\"r26\":%u,\"r28\":%u,\"r30\":%u,\"sample_begin_ticks\":%llu,\"sample_end_ticks\":%llu}",round?",":"",r->round,r->thread,r->pc,r->lr,r->toc,r->sp,r->word,r->word_ok,r->r3,r->r4,r->r5,r->r6,r->r7,r->r8,r->r9,r->r24,r->r25,r->r26,r->r28,r->r30,(unsigned long long)r->begin_ticks,(unsigned long long)r->end_ticks);}
 printf("]}\n");return errors||drops||fixture_failures?4:0;
}
