/* Unscored-only coherent bounded one-thread stack discovery. No audio API. */
#include <mach/mach.h>
#include <mach/ppc/thread_status.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <limits.h>
#define RECORD_CAP 128
#define READ_CAP 80
#define FRAME_CAP 32
#define STACK_CAP 32
struct extent {unsigned lo,hi;};
struct readrec {unsigned address,n;unsigned char bytes[16];};
struct frame {unsigned frame,backchain,lr_address,lr;};
struct candidate {unsigned inner,wrapper,caller,record,hw,device,inner_lr,wrapper_lr;unsigned char slots[20];};
struct record {unsigned round,thread,pc,lr,sp,word,word_ok,r3,r4,r5,r6,r7,r8,r9,r24,r25,r26,r28,r30,lo,hi,nread,nframe,ncandidate,capture_error,suspend_ok,resume_ok;int resume_status;uint64_t begin,end;struct readrec reads[READ_CAP];struct frame frames[FRAME_CAP];struct candidate candidates[2];};
static struct record records[RECORD_CAP];static struct extent stacks[STACK_CAP];static unsigned nstack,nrec,errors,drops,suspended,resumed,resume_errors,self_skips,bytes_read;static volatile sig_atomic_t stopflag;static mach_timebase_info_data_t tb;static uint64_t started;static unsigned low,high,smret,coreret;static mach_port_t task;static unsigned inject,fixture_unexpected;
static void stop_handler(int sig){(void)sig;stopflag=1;}
static unsigned word(const unsigned char*b){return ((unsigned)b[0]<<24)|((unsigned)b[1]<<16)|((unsigned)b[2]<<8)|b[3];}
static int budget(uint64_t a,unsigned ms){return (mach_absolute_time()-a)*tb.numer/tb.denom>(uint64_t)ms*1000000ULL;}
static int contains(unsigned a,unsigned n,unsigned lo,unsigned hi){return n && a>=lo && a<=UINT_MAX-n && a+n<=hi;}
static int readmem(struct record*r,unsigned a,unsigned n,unsigned char*out,int stack){vm_size_t got=0;kern_return_t k;if(n>16||r->nread==READ_CAP||bytes_read>4*1024*1024-n)return 0;if(stack&&!contains(a,n,r->lo,r->hi))return 0;if(stopflag||budget(r->begin,20)||budget(started,8000))return 0;k=vm_read_overwrite(task,a,n,(vm_address_t)out,&got);if(k!=KERN_SUCCESS||got!=n)return 0;bytes_read+=n;r->reads[r->nread].address=a;r->reads[r->nread].n=n;memcpy(r->reads[r->nread++].bytes,out,n);return 1;}
static int capture(struct record*r,thread_t t){ppc_thread_state_t st;mach_msg_type_number_t count=PPC_THREAD_STATE_COUNT;unsigned i,cur,next,j;unsigned char b[16],lr[4],x[8],y[4],z[4],q[4];kern_return_t k;k=thread_get_state(t,PPC_THREAD_STATE,(thread_state_t)&st,&count);if(k!=KERN_SUCCESS||count!=PPC_THREAD_STATE_COUNT)return 0;if(inject==1){count=0;k=thread_get_state(t,-1,(thread_state_t)&st,&count);if(k==KERN_SUCCESS)fixture_unexpected++;return 0;}
 r->pc=st.srr0;r->lr=st.lr;r->sp=st.r1;r->r3=st.r3;r->r4=st.r4;r->r5=st.r5;r->r6=st.r6;r->r7=st.r7;r->r8=st.r8;r->r9=st.r9;r->r24=st.r24;r->r25=st.r25;r->r26=st.r26;r->r28=st.r28;r->r30=st.r30;
 if(!(st.srr0>=low&&st.srr0<high))return 2; /* coherent state moved outside selected code: no attribution */
 if(!readmem(r,st.srr0,4,b,0))return 0;r->word=word(b);r->word_ok=1;
 for(i=0;i<nstack;i++)if(contains(st.r1,16,stacks[i].lo,stacks[i].hi)){r->lo=stacks[i].lo;r->hi=stacks[i].hi;break;}
 if(!r->lo || st.r1%16)return 0;cur=st.r1;
 for(i=0;i<FRAME_CAP;i++){
  if(inject==4){kill(getpid(),SIGTERM);if(!stopflag){fixture_unexpected++;stop_handler(SIGTERM);}return 0;}if(inject==5){usleep(25000);if(!budget(r->begin,20))fixture_unexpected++;return 0;}
  if(inject==2){vm_size_t badgot=0;k=vm_read_overwrite(task,0,4,(vm_address_t)b,&badgot);if(k==KERN_SUCCESS)fixture_unexpected++;return 0;}if(!readmem(r,cur,16,b,1))return 0;next=word(b);
  if(!next)break;
  if(next%16||next<=cur||next-cur>4096||next-st.r1>65536||!contains(next,16,r->lo,r->hi))return 0;
  if(!readmem(r,next+8,4,lr,1))return 0;r->frames[r->nframe++]=(struct frame){cur,next,next+8,word(lr)};cur=next;
 }
 if(i==FRAME_CAP)return 0; /* capped partial walk is not a complete coherent proof */
 for(j=0;j+1<r->nframe;j++){
  struct frame*f=&r->frames[j],*w=&r->frames[j+1];struct candidate*c;
  if(f->backchain-f->frame!=0x90||w->frame!=f->backchain||w->backchain-w->frame!=0x50||f->lr!=smret||w->lr!=coreret)continue;
  if(r->ncandidate==2)return 0;if(inject==3){vm_size_t badgot=0;k=vm_read_overwrite(task,0,4,(vm_address_t)b,&badgot);if(k==KERN_SUCCESS)fixture_unexpected++;return 0;}
  if(!readmem(r,f->frame+0x84,8,x,1)||!readmem(r,w->frame+0x48,4,y,1)||!readmem(r,w->frame+8,4,z,1)||!readmem(r,w->backchain+8,4,q,1))return 0;
  c=&r->candidates[r->ncandidate++];c->inner=f->frame;c->wrapper=w->frame;c->caller=w->backchain;c->record=word(x);c->hw=word(x+4);c->device=word(y);c->inner_lr=word(z);c->wrapper_lr=word(q);memcpy(c->slots,x,8);memcpy(c->slots+8,y,4);memcpy(c->slots+12,z,4);memcpy(c->slots+16,q,4);
 }
 return r->ncandidate<=1;
}
static int sample(thread_t t,unsigned round){struct record*r;int ok;kern_return_t k;if(nrec==RECORD_CAP){drops++;return 0;}r=&records[nrec++];memset(r,0,sizeof(*r));r->round=round;r->thread=t;r->begin=mach_absolute_time();k=thread_suspend(t);if(k!=KERN_SUCCESS){errors++;r->capture_error=1;return 0;}r->suspend_ok=1;suspended++;
 /* No exits, printf, allocation or object discovery between suspend and exactly one resume. */
 ok=capture(r,t);if(!ok){errors++;r->capture_error=1;}k=thread_resume(t);r->resume_status=k;r->resume_ok=k==KERN_SUCCESS;if(k==KERN_SUCCESS)resumed++;else{resume_errors++;errors++;}r->end=mach_absolute_time();return ok && k==KERN_SUCCESS;
}
static void hex(const unsigned char*b,unsigned n){unsigned i;for(i=0;i<n;i++)printf("%02x",b[i]);}
static void output(unsigned pid,unsigned rounds,int fixture){unsigned i,j;printf("{\"schema\":2,\"provenance\":\"coherent-suspended-stack\",\"pid\":%u,\"range_low\":%u,\"range_high\":%u,\"sm_return\":%u,\"core_return\":%u,\"rounds\":%u,\"errors\":%u,\"drops\":%u,\"suspend_successes\":%u,\"resume_successes\":%u,\"resume_errors\":%u,\"self_thread_skips\":%u,\"total_stack_bytes\":%u,\"stop_requested\":%s,\"fixture\":%s,\"records\":[",pid,low,high,smret,coreret,rounds,errors,drops,suspended,resumed,resume_errors,self_skips,bytes_read,stopflag?"true":"false",fixture?"true":"false");for(i=0;i<nrec;i++){struct record*r=&records[i];printf("%s{\"round\":%u,\"thread\":%u,\"pc\":%u,\"lr\":%u,\"sp\":%u,\"word\":%u,\"word_ok\":%u,\"r3\":%u,\"r4\":%u,\"r5\":%u,\"r6\":%u,\"r7\":%u,\"r8\":%u,\"r9\":%u,\"r24\":%u,\"r25\":%u,\"r26\":%u,\"r28\":%u,\"r30\":%u,\"stack_lo\":%u,\"stack_hi\":%u,\"capture_begin_ticks\":%llu,\"capture_end_ticks\":%llu,\"capture_error\":%u,\"suspend_ok\":%u,\"resume_ok\":%u,\"resume_status\":%d,\"reads\":[",i?",":"",r->round,r->thread,r->pc,r->lr,r->sp,r->word,r->word_ok,r->r3,r->r4,r->r5,r->r6,r->r7,r->r8,r->r9,r->r24,r->r25,r->r26,r->r28,r->r30,r->lo,r->hi,(unsigned long long)r->begin,(unsigned long long)r->end,r->capture_error,r->suspend_ok,r->resume_ok,r->resume_status);
 for(j=0;j<r->nread;j++){printf("%s{\"address\":%u,\"bytes\":%u,\"bytes_hex\":\"",j?",":"",r->reads[j].address,r->reads[j].n);hex(r->reads[j].bytes,r->reads[j].n);printf("\"}");}printf("],\"frames\":[");for(j=0;j<r->nframe;j++){struct frame*f=&r->frames[j];printf("%s{\"frame\":%u,\"backchain\":%u,\"lr_address\":%u,\"lr\":%u}",j?",":"",f->frame,f->backchain,f->lr_address,f->lr);}printf("],\"candidates\":[");for(j=0;j<r->ncandidate;j++){struct candidate*c=&r->candidates[j];printf("%s{\"inner_frame\":%u,\"wrapper_frame\":%u,\"caller_frame\":%u,\"record\":%u,\"hw\":%u,\"device\":%u,\"inner_return\":%u,\"wrapper_return\":%u,\"rawslotshex\":\"",j?",":"",c->inner,c->wrapper,c->caller,c->record,c->hw,c->device,c->inner_lr,c->wrapper_lr);hex(c->slots,20);printf("\"}");}printf("]}");}printf("]}\n");}
extern unsigned char pe_stack_loop[],pe_stack_loop_end[],pe_stack_inner_return[],pe_stack_outer_return[];static volatile unsigned progress;static volatile unsigned stack_ready;
static void*worker(void*unused){(void)unused;stacks[0].hi=(unsigned)pthread_get_stackaddr_np(pthread_self());stacks[0].lo=stacks[0].hi-(unsigned)pthread_get_stacksize_np(pthread_self());stack_ready=1;
 __asm__ volatile("li r29,0x129\nli r30,0x130\nli r9,0x109\nbl _pe_stack_wrapper\n.globl _pe_stack_outer_return\n_pe_stack_outer_return:\nb _pe_stack_outer_return\n_pe_stack_wrapper:\nmflr r3\nstmw r30,-8(r1)\nstw r3,8(r1)\nmr r30,r9\nstwu r1,-0x50(r1)\nbl _pe_stack_inner\n.globl _pe_stack_inner_return\n_pe_stack_inner_return:\nb _pe_stack_inner_return\n_pe_stack_inner:\nmflr r2\nstmw r22,-0x28(r1)\nstw r2,8(r1)\nstwu r1,-0x90(r1)\nli r29,0x229\nlis r12,ha16(_progress)\naddi r12,r12,lo16(_progress)\n.globl _pe_stack_loop\n_pe_stack_loop:\nlwz r10,0(r12)\naddi r10,r10,1\nstw r10,0(r12)\nb _pe_stack_loop\n.globl _pe_stack_loop_end\n_pe_stack_loop_end:\n");return 0;}
static unsigned parse(const char*s,int base){char*e;unsigned long v;errno=0;v=strtoul(s,&e,base);if(errno||*e||v>UINT_MAX||!v)exit(2);return (unsigned)v;}
int main(int argc,char**argv){unsigned pid,round,j,countfound=0;thread_act_array_t threads;mach_msg_type_number_t count;thread_t self=mach_thread_self(),target=0;unsigned acquired=0;kern_return_t k;int fixture=argc==2&&!strcmp(argv[1],"--self-test");pthread_t w;signal(SIGTERM,stop_handler);signal(SIGINT,stop_handler);signal(SIGHUP,stop_handler);if(mach_timebase_info(&tb)!=KERN_SUCCESS||!tb.denom)return 2;started=mach_absolute_time();
 if(fixture){task=mach_task_self();pid=getpid();if(pthread_create(&w,0,worker,0))return 2;for(j=0;!stack_ready&&j<100;j++)usleep(1000);if(!stack_ready)return 2;nstack=1;low=(unsigned)pe_stack_loop;high=(unsigned)pe_stack_loop_end;smret=(unsigned)pe_stack_inner_return;coreret=(unsigned)pe_stack_outer_return;}
 else{FILE*f;unsigned a,b;if(argc!=7)return 2;pid=parse(argv[1],10);if(pid<2||pid>INT_MAX)return 2;low=parse(argv[2],16);high=parse(argv[3],16);smret=parse(argv[5],16);coreret=parse(argv[6],16);if(low<4096||high<=low||high-low>1024*1024)return 2;f=fopen(argv[4],"r");if(!f)return 2;while(fscanf(f,"%x %x",&a,&b)==2){if(nstack==STACK_CAP||a%4096||b%4096||a>=b||b-a>64*1024*1024)return 2;for(j=0;j<nstack;j++)if(a<stacks[j].hi&&b>stacks[j].lo)return 2;stacks[nstack++]=(struct extent){a,b};}if(!feof(f)||!nstack){fclose(f);return 2;}fclose(f);if(task_for_pid(mach_task_self(),pid,&task)!=KERN_SUCCESS)return 3;}
 for(round=0;round<(fixture?1U:500U)&&!acquired&&!stopflag&&!budget(started,8000)&&nrec<RECORD_CAP;round++){
  k=task_threads(task,&threads,&count);if(k!=KERN_SUCCESS){errors++;break;}if(count>1024){errors++;for(j=0;j<count;j++)mach_port_deallocate(mach_task_self(),threads[j]);vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));break;}
  for(j=0;j<count;j++){ppc_thread_state_t st;mach_msg_type_number_t sc=PPC_THREAD_STATE_COUNT;if(threads[j]==self){self_skips++;continue;}k=thread_get_state(threads[j],PPC_THREAD_STATE,(thread_state_t)&st,&sc);if(k!=KERN_SUCCESS||sc!=PPC_THREAD_STATE_COUNT){errors++;continue;}if(st.srr0>=low&&st.srr0<high){countfound++;if(fixture){target=threads[j];mach_port_mod_refs(mach_task_self(),target,MACH_PORT_RIGHT_SEND,1);}sample(threads[j],round);if(!fixture && records[nrec-1].ncandidate==1 && !records[nrec-1].capture_error && records[nrec-1].resume_ok)acquired=1;if(resume_errors||acquired)break;}}
  for(j=0;j<count;j++)mach_port_deallocate(mach_task_self(),threads[j]);vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));if(resume_errors||acquired)break;usleep(10000);
 }
 if(fixture&&target){unsigned before,after,ix;int ok=1;for(ix=1;ix<=5;ix++){unsigned prior=suspended;inject=ix;stopflag=0;before=progress;sample(target,ix);usleep(1000);after=progress;if(suspended!=prior+1||suspended!=resumed||resume_errors||after==before)ok=0;}inject=0;stopflag=0;if(fixture_unexpected||!ok||!records[0].ncandidate||records[0].candidates[0].record!=0x129||records[0].candidates[0].hw!=0x109||records[0].candidates[0].device!=0x130||!self_skips)errors++;mach_port_deallocate(mach_task_self(),target);}
 if(!fixture && nrec==RECORD_CAP && !acquired)drops++;
 mach_port_deallocate(mach_task_self(),self);if(!fixture)mach_port_deallocate(mach_task_self(),task);output(pid,round,fixture);if(fixture)return !countfound||resume_errors||suspended!=resumed||errors!=5;return errors||drops||resume_errors||stopflag?4:0;
}
