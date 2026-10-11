/* Default-off stopped-flush observer of the EXISTING registered SoundManager IOProc. */
#include <qemu-plugin.h>
#include <glib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
QEMU_PLUGIN_EXPORT int qemu_plugin_version=QEMU_PLUGIN_VERSION;
#define NCPU 16
#define CAP 8192
#define READY 0x534d5031U
#define NPR 10
#define NPAIR 64
#define NSTACK 32
/* Published once with owned VM paused, after fresh ownership/code/SDK gates. */
typedef struct {atomic_uint ready;uint32_t version,entry,exit,entry_word,exit_word,device_id,hw,record,device,bridge,abl,abl_lo,abl_hi,stack_count,numer,denom,delay_sec,window_sec,core_return,reserved,context_address,context_words[4];uint64_t nonce;uint32_t stacks[NSTACK][2];} Control;
_Static_assert(sizeof(Control)==368,"control ABI");
typedef struct {uint64_t ns,end_ns,exit_ns,sp,lr,serial;uint32_t device_id,hw,nowptr,outptr,ablptr,entry_cpu,exit_cpu,buffers;uint8_t now[64],out[64],abl[100],reserved[12];} Rec;
_Static_assert(sizeof(Rec)==320,"record ABI");
typedef struct {bool active;uint64_t sp,lr;size_t index;} Pair;
typedef struct {struct qemu_plugin_register*reg[NPR];GByteArray*scratch,*memory;bool supported;uint64_t reg_errors,priv_skips,identity_skips,window_skips,pre_skips;} CPU;
typedef struct {uint32_t pc,word;bool entry,good;} Site;
static CPU cpus[NCPU];static int ncpu;static Site sites[2],bad[2];static const Control*page;static Control config;static atomic_bool latched;static uint64_t observed,start,end;static Rec*records;static size_t count;static Pair pairs[NPAIR];static char*output;static atomic_flag guard=ATOMIC_FLAG_INIT;
static atomic_uint_fast64_t config_errors,guard_errors,word_errors,read_errors,bounds_errors,torn_reads,context_skips,object_errors,drops,pair_errors,unmatched_exits,translated,reg_reads,memory_reads;
static uint32_t first_failed_regs[NPR];static unsigned first_failed_cpu;static uint64_t first_failed_ns;
static const char*names[NPR]={"r1","lr","r3","r4","r5","r6","r7","r8","r9","msr"};
static uint64_t clock_ns(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return (uint64_t)t.tv_sec*1000000000ULL+t.tv_nsec;}
static uint32_t be32(const uint8_t*b){return (uint32_t)b[0]<<24|(uint32_t)b[1]<<16|(uint32_t)b[2]<<8|b[3];}
static bool span(uint32_t p,size_t n,uint32_t lo,uint32_t hi){return p>=4096&&p>=lo&&hi>lo&&n<=hi-lo&&p<=hi-n;}
static bool stack(uint32_t p,size_t n){for(unsigned i=0;i<config.stack_count;i++)if(span(p,n,config.stacks[i][0],config.stacks[i][1]))return true;return false;}
static bool valid_config(const Control*c){
 if(c->version!=1||c->entry!=sites[0].pc||c->exit!=sites[1].pc||c->entry_word!=sites[0].word||c->exit_word!=sites[1].word||!c->device_id||c->hw<4096||c->record<4096||c->device<4096||c->bridge<4096||c->record>UINT32_MAX-0xa4||c->device>UINT32_MAX-0x6c||c->hw>UINT32_MAX-0x2c||c->bridge>UINT32_MAX-16||c->hw%4||c->record%4||c->device%4||c->bridge%4||c->context_address<4096||c->context_address>UINT32_MAX-16||c->context_address%4||!c->nonce||!c->numer||!c->denom||c->delay_sec>10||!c->window_sec||c->window_sec>60||c->reserved||c->core_return<4096||c->core_return%4||!c->stack_count||c->stack_count>NSTACK||!span(c->abl,4,c->abl_lo,c->abl_hi))return false;
 for(unsigned i=0;i<c->stack_count;i++){uint32_t lo=c->stacks[i][0],hi=c->stacks[i][1];if(lo<4096||lo%4096||hi%4096||hi<=lo||hi-lo>64*1024*1024)return false;for(unsigned j=0;j<i;j++)if(lo<c->stacks[j][1]&&c->stacks[j][0]<hi)return false;}
 for(unsigned i=c->stack_count;i<NSTACK;i++)if(c->stacks[i][0]||c->stacks[i][1])return false;return true;
}
static bool publication(uint64_t ns){
 unsigned r=atomic_load_explicit(&page->ready,memory_order_acquire);if(!r)return false;if(r!=READY){config_errors++;return false;}
 Control c;memcpy(&c,page,sizeof(c));if(atomic_load_explicit(&page->ready,memory_order_acquire)!=READY){config_errors++;return false;}
 if(latched){if(memcmp(&c,&config,sizeof(c))){config_errors++;return false;}return true;}
 if(!valid_config(&c)){config_errors++;return false;}memcpy(&config,&c,sizeof(c));observed=ns;start=ns+(uint64_t)c.delay_sec*1000000000ULL;end=start+(uint64_t)c.window_sec*1000000000ULL;latched=true;return true;
}
static bool readreg(CPU*c,int i,uint32_t*out){g_byte_array_set_size(c->scratch,0);reg_reads++;int n=qemu_plugin_read_register(c->reg[i],c->scratch);if((n!=4&&n!=8)||c->scratch->len!=(guint)n)return false;if(n==8&&be32(c->scratch->data))return false;*out=be32(c->scratch->data+n-4);return true;}
static bool readmem(unsigned cpu,uint32_t addr,size_t n,uint8_t*out){if(n>100||addr<4096||addr>UINT32_MAX-n)return false;GByteArray*b=cpus[cpu].memory;g_byte_array_set_size(b,0);memory_reads++;if(!qemu_plugin_read_memory_vaddr(addr,b,n)||b->len!=n)return false;memcpy(out,b->data,n);return true;}
static bool snapshot(unsigned cpu,const uint32_t*r,Rec*out){
 uint8_t object[12],p4[4];if(!readmem(cpu,config.record,12,object)||!readmem(cpu,config.record+0xa0,4,p4)){read_errors++;return false;}if(be32(object)!=config.device||be32(object+4)!=config.bridge||be32(object+8)!=config.hw||be32(p4)!=config.abl){object_errors++;return false;}
 uint8_t again[100];uint32_t now=r[3],abl=r[6],ts=r[7];
 if(!stack(now,64)||!stack(ts,64)||abl!=config.abl||!span(abl,4,config.abl_lo,config.abl_hi)){bounds_errors++;return false;}
 if(!readmem(cpu,now,64,out->now)||!readmem(cpu,ts,64,out->out)||!readmem(cpu,abl,4,out->abl)){read_errors++;return false;}
 uint32_t n=be32(out->abl);if(n>8){bounds_errors++;return false;}size_t bytes=4+12*n;if(!span(abl,bytes,config.abl_lo,config.abl_hi)){bounds_errors++;return false;}
 if(!readmem(cpu,abl,bytes,out->abl)||!readmem(cpu,now,64,again)){read_errors++;return false;}if(memcmp(out->now,again,64)){torn_reads++;return false;}
 if(!readmem(cpu,ts,64,again)){read_errors++;return false;}if(memcmp(out->out,again,64)){torn_reads++;return false;}
 if(!readmem(cpu,abl,bytes,again)){read_errors++;return false;}if(memcmp(out->abl,again,bytes)){torn_reads++;return false;}
 /* Raw AudioBuffer DATA pointers are retained, never followed or treated as frame counts. */
 out->nowptr=now;out->outptr=ts;out->ablptr=abl;out->buffers=n;return true;
}
static void observe(unsigned cpu,void*opaque){
 if(cpu>=(unsigned)ncpu)return;CPU*c=&cpus[cpu];Site*s=opaque;uint64_t ns=clock_ns();if(!ns){c->reg_errors++;return;}
 if(!atomic_load_explicit(&page->ready,memory_order_acquire)){c->pre_skips++;return;}
 if(latched&&(ns<start||ns>=end)){c->window_skips++;return;}
 if(atomic_flag_test_and_set_explicit(&guard,memory_order_acquire)){guard_errors++;return;}
 if(!publication(ns))goto done;if(ns<start||ns>=end){c->window_skips++;goto done;}
 if(!c->supported){c->reg_errors++;goto done;}
 if(!s->good){word_errors++;goto done;}
 uint32_t r[NPR];for(int i=0;i<10;i++)if(!readreg(c,i,&r[i])){c->reg_errors++;goto done;}
 if(!(r[9]&(1U<<14))){c->priv_skips++;goto done;}
 if(!stack(r[0],16)||r[1]!=config.core_return){c->identity_skips++;goto done;}
 if(s->entry&&(r[2]!=config.device_id||r[8]!=config.hw)){c->identity_skips++;goto done;}
 uint8_t anchor[16];if(!readmem(cpu,config.context_address,16,anchor)){context_skips++;goto done;}for(unsigned j=0;j<4;j++)if(be32(anchor+4*j)!=config.context_words[j]){context_skips++;goto done;}
 if(s->entry){
  for(unsigned i=0;i<NPAIR;i++)if(pairs[i].active&&pairs[i].sp==r[0]&&pairs[i].lr==r[1]){pair_errors++;goto done;}
  unsigned slot=NPAIR;for(unsigned i=0;i<NPAIR;i++)if(!pairs[i].active){slot=i;break;}if(slot==NPAIR){pair_errors++;goto done;}
  if(count==CAP){drops++;goto done;}Rec temp={.ns=ns,.sp=r[0],.lr=r[1],.serial=count,.device_id=r[2],.hw=r[8],.entry_cpu=cpu,.exit_cpu=UINT32_MAX};
  if(!snapshot(cpu,r,&temp)){if(!first_failed_ns){first_failed_ns=ns;first_failed_cpu=cpu;memcpy(first_failed_regs,r,sizeof(first_failed_regs));}goto done;}temp.end_ns=clock_ns();records[count]=temp;pairs[slot]=(Pair){true,r[0],r[1],count};count++;
 }else{
  unsigned found=NPAIR;for(unsigned i=0;i<NPAIR;i++)if(pairs[i].active&&pairs[i].sp==r[0]&&pairs[i].lr==r[1]){if(found!=NPAIR){pair_errors++;goto done;}found=i;}
  if(found==NPAIR){unmatched_exits++;goto done;}records[pairs[found].index].exit_ns=ns;records[pairs[found].index].exit_cpu=cpu;pairs[found].active=false;
 }
 done:atomic_flag_clear_explicit(&guard,memory_order_release);
}
static void init(qemu_plugin_id_t id,unsigned cpu){if(cpu>=(unsigned)ncpu)return;CPU*c=&cpus[cpu];GArray*a=qemu_plugin_get_registers();bool unique=true;for(guint i=0;a&&i<a->len;i++){qemu_plugin_reg_descriptor*d=&g_array_index(a,qemu_plugin_reg_descriptor,i);if(!d->feature||strcmp(d->feature,"org.gnu.gdb.power.core"))continue;for(int j=0;j<NPR;j++)if(!strcmp(d->name,names[j])){if(c->reg[j])unique=false;else c->reg[j]=d->handle;}}
 if(a)g_array_free(a,true);c->supported=unique;for(int j=0;j<10;j++)if(!c->reg[j])c->supported=false;c->scratch=g_byte_array_sized_new(16);g_byte_array_set_size(c->scratch,16);memset(c->scratch->data,0,16);g_byte_array_set_size(c->scratch,0);c->memory=g_byte_array_sized_new(100);g_byte_array_set_size(c->memory,100);memset(c->memory->data,0,100);g_byte_array_set_size(c->memory,0);
}
static void translate(qemu_plugin_id_t id,struct qemu_plugin_tb*tb){for(size_t i=0;i<qemu_plugin_tb_n_insns(tb);i++){struct qemu_plugin_insn*in=qemu_plugin_tb_get_insn(tb,i);uint64_t pc=qemu_plugin_insn_vaddr(in);for(unsigned j=0;j<2;j++)if(pc==sites[j].pc){uint8_t b[4];bool good=qemu_plugin_insn_size(in)==4&&qemu_plugin_insn_data(in,b,4)==4&&be32(b)==sites[j].word;qemu_plugin_register_vcpu_insn_exec_cb(in,observe,QEMU_PLUGIN_CB_R_REGS,good?&sites[j]:&bad[j]);translated++;}}}
static void finish(qemu_plugin_id_t id,void*unused){uint64_t unfinished=0;for(unsigned i=0;i<NPAIR;i++)if(pairs[i].active)unfinished++;if(latched&&memcmp(page,&config,sizeof(config)))config_errors++;
 char*p=g_strdup_printf("%s.records",output);FILE*f=fopen(p,"wb");bool ok=f!=NULL;if(f){if(fwrite(records,sizeof(Rec),count,f)!=count)ok=false;if(fclose(f))ok=false;}g_free(p);
 p=g_strdup_printf("%s.config",output);f=fopen(p,"wb");if(!f)ok=false;else{if(fwrite(&config,sizeof(config),1,f)!=1)ok=false;if(fclose(f))ok=false;}g_free(p);
 p=g_strdup_printf("%s.json",output);f=fopen(p,"w");if(!f)ok=false;else{fprintf(f,"{\"schema\":1,\"clock\":\"CLOCK_MONOTONIC\",\"record_bytes\":%zu,\"records\":%zu,\"capacity\":%u,\"latched\":%s,\"publication_observed_ns\":%llu,\"arm_start_ns\":%llu,\"arm_end_ns\":%llu,\"config_errors\":%llu,\"guard_errors\":%llu,\"word_errors\":%llu,\"read_errors\":%llu,\"bounds_errors\":%llu,\"torn_reads\":%llu,\"context_skips\":%llu,\"object_errors\":%llu,\"drops\":%llu,\"pair_errors\":%llu,\"unmatched_exits\":%llu,\"unfinished\":%llu,\"register_reads\":%llu,\"memory_reads\":%llu,\"translated\":%llu,\"guest_timestamp_clock_not_host\":true,\"abl_byte_counts_not_frames\":true,\"first_failure\":",sizeof(Rec),count,CAP,latched?"true":"false",(unsigned long long)observed,(unsigned long long)start,(unsigned long long)end,(unsigned long long)config_errors,(unsigned long long)guard_errors,(unsigned long long)word_errors,(unsigned long long)read_errors,(unsigned long long)bounds_errors,(unsigned long long)torn_reads,(unsigned long long)context_skips,(unsigned long long)object_errors,(unsigned long long)drops,(unsigned long long)pair_errors,(unsigned long long)unmatched_exits,(unsigned long long)unfinished,(unsigned long long)reg_reads,(unsigned long long)memory_reads,(unsigned long long)translated);
 fprintf(f,"{\"first_snapshot_failure_ns\":%llu,\"cpu\":%u,\"r1\":%u,\"lr\":%u,\"r3\":%u,\"r4\":%u,\"r5\":%u,\"r6\":%u,\"r7\":%u,\"r8\":%u,\"r9\":%u},",(unsigned long long)first_failed_ns,first_failed_cpu,first_failed_regs[0],first_failed_regs[1],first_failed_regs[2],first_failed_regs[3],first_failed_regs[4],first_failed_regs[5],first_failed_regs[6],first_failed_regs[7],first_failed_regs[8]);
 fputs("\"cpu\":[",f);
 for(int i=0;i<ncpu;i++)fprintf(f,"%s{\"id\":%d,\"supported\":%s,\"register_errors\":%llu,\"identity_skips\":%llu,\"privileged_skips\":%llu,\"window_skips\":%llu,\"prepublication_skips\":%llu}",i?",":"",i,cpus[i].supported?"true":"false",(unsigned long long)cpus[i].reg_errors,(unsigned long long)cpus[i].identity_skips,(unsigned long long)cpus[i].priv_skips,(unsigned long long)cpus[i].window_skips,(unsigned long long)cpus[i].pre_skips);fputs("]}\n",f);if(ferror(f))ok=false;if(fclose(f))ok=false;}g_free(p);
 p=g_strdup_printf("%s.flush.json",output);f=fopen(p,"w");if(f){fprintf(f,"{\"all_outputs_ok\":%s}\n",ok?"true":"false");if(fclose(f))fprintf(stderr,"SM final flush failed\n");}else fprintf(stderr,"SM final receipt open failed\n");g_free(p);
 munmap((void*)page,sizeof(Control));free(records);for(int i=0;i<ncpu;i++){if(cpus[i].scratch)g_byte_array_unref(cpus[i].scratch);if(cpus[i].memory)g_byte_array_unref(cpus[i].memory);}g_free(output);
}
QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,const qemu_info_t*info,int argc,char**argv){bool enabled=false;const char*out=NULL,*cp=NULL,*mf=NULL;for(int i=0;i<argc;i++){if(!strcmp(argv[i],"enabled=1"))enabled=true;else if(!strncmp(argv[i],"out=",4))out=argv[i]+4;else if(!strncmp(argv[i],"control=",8))cp=argv[i]+8;else if(!strncmp(argv[i],"sites=",6))mf=argv[i]+6;else return -1;}if(!enabled)return 0;
 if(!info->system_emulation||strncmp(info->target_name,"ppc",3)||info->system.max_vcpus<1||info->system.max_vcpus>NCPU||!out||out[0]!='/'||!cp||cp[0]!='/'||!mf||mf[0]!='/')return -1;
 FILE*f=fopen(mf,"r");char line[200];bool sha=false;unsigned n=0;if(!f)return -1;while(fgets(line,sizeof(line),f)){if(!strncmp(line,"# verified-source-sha256=",25)){char*s=line+25;size_t k=strcspn(s,"\n");sha=k==64;for(size_t j=0;j<k;j++)if(!g_ascii_isxdigit(s[j]))sha=false;continue;}if(line[0]=='#'||line[0]=='\n')continue;unsigned pc,w,phase;char extra;if(n==2||sscanf(line,"%x %x %u %c",&pc,&w,&phase,&extra)!=3||pc<4096||pc%4||phase!=n){fclose(f);return -1;}sites[n]=(Site){pc,w,n==0,true};bad[n]=(Site){pc,w,n==0,false};n++;}bool good=sha&&n==2&&!ferror(f);fclose(f);if(!good||sites[0].pc==sites[1].pc)return -1;
 int fd=open(cp,O_RDONLY|O_NOFOLLOW);struct stat st;if(fd<0)return -1;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&0777)!=0600||st.st_size!=sizeof(Control)){close(fd);return -1;}void*m=mmap(NULL,sizeof(Control),PROT_READ,MAP_SHARED,fd,0);close(fd);if(m==MAP_FAILED)return -1;page=m;if(atomic_load(&page->ready)){munmap(m,sizeof(Control));return -1;}
 records=calloc(CAP,sizeof(Rec));if(!records){munmap(m,sizeof(Control));return -1;}volatile uint8_t*b=(void*)records;for(size_t j=0;j<CAP*sizeof(Rec);j+=4096)b[j]=0;output=g_strdup(out);ncpu=info->system.max_vcpus;qemu_plugin_register_vcpu_init_cb(id,init);qemu_plugin_register_vcpu_tb_trans_cb(id,translate);qemu_plugin_register_atexit_cb(id,finish,NULL);return 0;
}
