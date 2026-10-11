/* Diagnostic-only, explicitly enabled TCG callback observer. No guest writes. */
#include <qemu-plugin.h>
#include <glib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;
#define MAX_CPUS 16
#define MAX_SITES 32
#define EVENT_CAPACITY 65536
#define MSR_PR (1U << 14)
typedef struct { uint64_t ns,pc,sp,lr; uint32_t r3,r4,r5,r6,msr,cpu,site,phase; } Event;
_Static_assert(sizeof(Event)==64,"event ABI");
typedef struct { uint64_t pc;uint32_t word,site,phase; } Site;
typedef struct {
 Event *events;size_t count;uint64_t drops,register_errors,privileged_skips;
 struct qemu_plugin_register *registers[7];GByteArray *scratch;bool supported;
} CPU;
static CPU cpus[MAX_CPUS];static Site sites[MAX_SITES];static size_t site_count;
static int cpu_limit;static char *output,*manifest;static atomic_uint_fast64_t word_mismatches,matched_translations;
static const char *names[7]={"r1","lr","r3","r4","r5","r6","msr"};
static bool hex64(const char *s){if(strlen(s)!=64)return false;for(int i=0;i<64;i++)if(!g_ascii_isxdigit(s[i]))return false;return true;}
static bool load_sites(const char *path){
 FILE*f=fopen(path,"r");if(!f)return false;char line[512];bool verified=false;size_t n=0;
 while(fgets(line,sizeof line,f)){
  if(strchr(line,'\n')==NULL&&!feof(f)){fclose(f);return false;}
  line[strcspn(line,"\r\n")]=0;
  if(!strncmp(line,"# verified-source-sha256=",25)){verified=hex64(line+25);continue;}
  if(!line[0]||line[0]=='#')continue;
  unsigned long long pc;unsigned word,id,phase;char extra;
  if(n==MAX_SITES||sscanf(line,"%llx %x %u %u %c",&pc,&word,&id,&phase,&extra)!=4||
     pc%4||pc>UINT32_MAX||!pc||phase>1||id>=MAX_SITES){fclose(f);return false;}
  for(size_t j=0;j<n;j++)if(sites[j].pc==pc){fclose(f);return false;}
  sites[n++]=(Site){pc,word,id,phase};
 }
 bool ok=!ferror(f)&&verified&&n;fclose(f);if(ok)site_count=n;return ok;
}
static void cpu_init(qemu_plugin_id_t id,unsigned index){
 if(index>=(unsigned)cpu_limit)return;CPU*c=&cpus[index];
 GArray*a=qemu_plugin_get_registers();
 for(guint i=0;a&&i<a->len;i++){
  qemu_plugin_reg_descriptor*r=&g_array_index(a,qemu_plugin_reg_descriptor,i);
  for(int j=0;j<7;j++)if(!strcmp(r->name,names[j]))c->registers[j]=r->handle;
 }
 if(a)g_array_free(a,true);c->supported=true;
 for(int j=0;j<7;j++)if(!c->registers[j])c->supported=false;
 /* Allocate/page-touch before execution; register reads append <=8 bytes. */
 c->scratch=g_byte_array_sized_new(64);g_byte_array_set_size(c->scratch,64);memset(c->scratch->data,0,64);g_byte_array_set_size(c->scratch,0);
}
static bool read_reg(CPU*c,int n,uint64_t*value){
 g_byte_array_set_size(c->scratch,0);int bytes=qemu_plugin_read_register(c->registers[n],c->scratch);
 if((bytes!=4&&bytes!=8)||c->scratch->len!=(guint)bytes)return false;
 uint64_t v=0;for(int j=0;j<bytes;j++)v=(v<<8)|c->scratch->data[j];*value=v;return true;
}
static void observe(unsigned index,void*opaque){
 if(index>=(unsigned)cpu_limit)return;CPU*c=&cpus[index];Site*s=opaque;
 if(!c->supported){c->register_errors++;return;}
 if(c->count==EVENT_CAPACITY){c->drops++;return;}
 uint64_t r[7];for(int j=0;j<7;j++)if(!read_reg(c,j,&r[j])){c->register_errors++;return;}
 if(!(r[6]&MSR_PR)){c->privileged_skips++;return;}
 struct timespec ts;if(clock_gettime(CLOCK_MONOTONIC,&ts)){c->register_errors++;return;}
 c->events[c->count++]=(Event){.ns=(uint64_t)ts.tv_sec*1000000000ULL+ts.tv_nsec,
 .pc=s->pc,.sp=r[0],.lr=r[1],.r3=r[2],.r4=r[3],.r5=r[4],.r6=r[5],.msr=r[6],.cpu=index,.site=s->site,.phase=s->phase};
}
static void translate(qemu_plugin_id_t id,struct qemu_plugin_tb*tb){
 for(size_t j=0;j<qemu_plugin_tb_n_insns(tb);j++){
  struct qemu_plugin_insn*insn=qemu_plugin_tb_get_insn(tb,j);uint64_t pc=qemu_plugin_insn_vaddr(insn);
  for(size_t k=0;k<site_count;k++)if(pc==sites[k].pc){
   uint8_t bytes[4];if(qemu_plugin_insn_size(insn)!=4||qemu_plugin_insn_data(insn,bytes,4)!=4){atomic_fetch_add(&word_mismatches,1);continue;}
   uint32_t word=((uint32_t)bytes[0]<<24)|((uint32_t)bytes[1]<<16)|((uint32_t)bytes[2]<<8)|bytes[3];
   if(word!=sites[k].word){atomic_fetch_add(&word_mismatches,1);continue;}
   qemu_plugin_register_vcpu_insn_exec_cb(insn,observe,QEMU_PLUGIN_CB_R_REGS,&sites[k]);atomic_fetch_add(&matched_translations,1);
  }
 }
}
static void finish(qemu_plugin_id_t id,void*p){
 char*path=g_strdup_printf("%s.events",output);FILE*f=fopen(path,"wb");bool ok=f!=NULL;
 if(f){for(int i=0;i<cpu_limit;i++)if(fwrite(cpus[i].events,sizeof(Event),cpus[i].count,f)!=cpus[i].count)ok=false;if(fclose(f))ok=false;}
 g_free(path);path=g_strdup_printf("%s.json",output);f=fopen(path,"w");
 if(f){fprintf(f,"{\"record_bytes\":%zu,\"clock\":\"CLOCK_MONOTONIC\",\"events_order\":\"grouped by CPU; sort by ns\",\"flush_ok\":%s,\"word_mismatches\":%llu,\"matched_translations\":%llu,\"cpu\":[",sizeof(Event),ok?"true":"false",(unsigned long long)atomic_load(&word_mismatches),(unsigned long long)atomic_load(&matched_translations));
  for(int i=0;i<cpu_limit;i++)fprintf(f,"%s{\"id\":%d,\"supported\":%s,\"records\":%zu,\"drops\":%llu,\"register_errors\":%llu,\"privileged_skips\":%llu}",i?",":"",i,cpus[i].supported?"true":"false",cpus[i].count,(unsigned long long)cpus[i].drops,(unsigned long long)cpus[i].register_errors,(unsigned long long)cpus[i].privileged_skips);
  fputs("]}\n",f);fclose(f);
 }
 g_free(path);for(int i=0;i<cpu_limit;i++){free(cpus[i].events);if(cpus[i].scratch)g_byte_array_unref(cpus[i].scratch);}g_free(output);g_free(manifest);
}
QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,const qemu_info_t*info,int argc,char**argv){
 bool enabled=false;const char*out=NULL,*input=NULL;
 for(int i=0;i<argc;i++){if(!strcmp(argv[i],"enabled=1"))enabled=true;else if(!strncmp(argv[i],"out=",4))out=argv[i]+4;else if(!strncmp(argv[i],"sites=",6))input=argv[i]+6;else return -1;}
 if(!enabled)return 0;
 if(!info->system_emulation||strncmp(info->target_name,"ppc",3)||!out||out[0]!='/'||!input||input[0]!='/'||info->system.max_vcpus<1||info->system.max_vcpus>MAX_CPUS||!load_sites(input))return -1;
 cpu_limit=info->system.max_vcpus;output=g_strdup(out);manifest=g_strdup(input);
 for(int i=0;i<cpu_limit;i++){cpus[i].events=calloc(EVENT_CAPACITY,sizeof(Event));if(!cpus[i].events)return -1;/* calloc may be lazy: force every page resident. */volatile unsigned char*b=(void*)cpus[i].events;for(size_t j=0;j<EVENT_CAPACITY*sizeof(Event);j+=4096)b[j]=0;}
 qemu_plugin_register_vcpu_init_cb(id,cpu_init);qemu_plugin_register_vcpu_tb_trans_cb(id,translate);qemu_plugin_register_atexit_cb(id,finish,NULL);return 0;
}
