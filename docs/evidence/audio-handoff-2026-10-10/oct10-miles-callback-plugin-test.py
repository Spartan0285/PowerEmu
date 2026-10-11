#!/usr/bin/env python3
"""ASan/UBSan fixture for disabled/manifest/word/register/overflow/flush guards."""
import subprocess,shlex,tempfile,json
from pathlib import Path
root=Path('/Users/adam/Developer/poweremu-qemu')
source=r'''
#include <assert.h>
#include "/tmp/pe9800/oct10-miles-callback-plugin.c"
struct qemu_plugin_insn {uint64_t pc;uint8_t bytes[4];size_t size;qemu_plugin_vcpu_udata_cb_t cb;void*data;};
struct qemu_plugin_tb {struct qemu_plugin_insn insns[3];size_t count;};
static int registrations,current_index;static bool missing_lr,bad_register,identity_mismatch,kernel_mode;static unsigned reg_reads;
static qemu_plugin_vcpu_simple_cb_t init_callback;
static qemu_plugin_vcpu_tb_trans_cb_t trans_callback;
static qemu_plugin_udata_cb_t exit_callback;
void qemu_plugin_register_vcpu_init_cb(qemu_plugin_id_t id,qemu_plugin_vcpu_simple_cb_t cb){init_callback=cb;registrations++;}
void qemu_plugin_register_vcpu_tb_trans_cb(qemu_plugin_id_t id,qemu_plugin_vcpu_tb_trans_cb_t cb){trans_callback=cb;registrations++;}
void qemu_plugin_register_atexit_cb(qemu_plugin_id_t id,qemu_plugin_udata_cb_t cb,void*data){exit_callback=cb;registrations++;}
GArray*qemu_plugin_get_registers(void){GArray*a=g_array_new(false,false,sizeof(qemu_plugin_reg_descriptor));for(int i=0;i<8;i++){if(missing_lr&&i==1)continue;qemu_plugin_reg_descriptor d={(void*)(uintptr_t)(i+1),names[i],NULL};g_array_append_val(a,d);}return a;}
int qemu_plugin_read_register(struct qemu_plugin_register*h,GByteArray*b){reg_reads++;if(bad_register)return -1;int n=(uintptr_t)h-1;uint32_t v=n==6?(kernel_mode?0:MSR_PR):n==7?(identity_mismatch?0x3b2000:0x3a2000):(0x123000+n);uint8_t bytes[4]={v>>24,v>>16,v>>8,v};g_byte_array_append(b,bytes,4);return 4;}
size_t qemu_plugin_tb_n_insns(const struct qemu_plugin_tb*t){return t->count;}
struct qemu_plugin_insn*qemu_plugin_tb_get_insn(const struct qemu_plugin_tb*t,size_t n){return (struct qemu_plugin_insn*)&t->insns[n];}
uint64_t qemu_plugin_insn_vaddr(const struct qemu_plugin_insn*i){return i->pc;}
size_t qemu_plugin_insn_size(const struct qemu_plugin_insn*i){return i->size;}
size_t qemu_plugin_insn_data(const struct qemu_plugin_insn*i,void*p,size_t n){size_t m=MIN(n,i->size);memcpy(p,i->bytes,m);return m;}
void qemu_plugin_register_vcpu_insn_exec_cb(struct qemu_plugin_insn*i,qemu_plugin_vcpu_udata_cb_t cb,enum qemu_plugin_cb_flags flags,void*p){assert(flags==QEMU_PLUGIN_CB_R_REGS);i->cb=cb;i->data=p;}
int main(int argc,char**argv){
 qemu_info_t info={.target_name="ppc64",.system_emulation=true,.system={.max_vcpus=2}};
 assert(qemu_plugin_install(1,&info,0,NULL)==0&&registrations==0);
 char*enabled="enabled=1";char*out=g_strdup_printf("out=%s/events",argv[1]);char*manifest_arg=g_strdup_printf("sites=%s/sites",argv[1]);char*args[]={enabled,out,manifest_arg,"arm-after-sec=0","window-sec=120","toc=3a2000"};
 assert(qemu_plugin_install(1,&info,6,args)==-1&&registrations==0);
 char*path=g_strdup_printf("%s/sites",argv[1]);FILE*f=fopen(path,"w");assert(f);fputs("1000 7c0802a6 0 0\n",f);fclose(f);
 assert(qemu_plugin_install(1,&info,6,args)==-1&&registrations==0);
 f=fopen(path,"w");fputs("# verified-source-sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n1000 7c0802a6 0 0\n1004 4e800020 0 1\n",f);fclose(f);
 char *valid=args[5];args[5]="toc=0";assert(qemu_plugin_install(1,&info,6,args)==-1);args[5]=valid;
 valid=args[3];args[3]="arm-after-sec=";assert(qemu_plugin_install(1,&info,6,args)==-1);args[3]="arm-after-sec=601";assert(qemu_plugin_install(1,&info,6,args)==-1);args[3]=valid;
 valid=args[4];args[4]="window-sec=121";assert(qemu_plugin_install(1,&info,6,args)==-1);args[4]=valid;
 assert(qemu_plugin_install(1,&info,6,args)==0&&registrations==3);
 init_callback(1,0);assert(cpus[0].supported);missing_lr=true;init_callback(1,1);assert(!cpus[1].supported);
 struct qemu_plugin_tb tb={.count=3,.insns={{.pc=0x1000,.size=4,.bytes={0x7c,0x08,0x02,0xa6}},{.pc=0x1004,.size=4,.bytes={0x4e,0x80,0,0x20}},{.pc=0x2000,.size=4}}};
 trans_callback(1,&tb);assert(tb.insns[0].cb&&tb.insns[1].cb&&!tb.insns[2].cb);
 tb.insns[0].cb(0,tb.insns[0].data);tb.insns[1].cb(0,tb.insns[1].data);
 assert(cpus[0].count==2&&cpus[0].events[0].sp==0x123000&&cpus[0].events[1].phase==1);
 unsigned reads=reg_reads;uint64_t saved_start=arm_start_ns,saved_end=arm_end_ns;
 arm_start_ns=UINT64_MAX;tb.insns[0].cb(0,tb.insns[0].data);assert(cpus[0].count==2&&reg_reads==reads&&cpus[0].window_skips==1);
 arm_start_ns=0;arm_end_ns=1;tb.insns[1].cb(0,tb.insns[1].data);assert(cpus[0].count==2&&reg_reads==reads&&cpus[0].window_skips==2);
 arm_start_ns=saved_start;arm_end_ns=saved_end;
 identity_mismatch=true;tb.insns[0].cb(0,tb.insns[0].data);identity_mismatch=false;assert(cpus[0].identity_skips==1&&cpus[0].count==2);
 kernel_mode=true;tb.insns[1].cb(0,tb.insns[1].data);kernel_mode=false;assert(cpus[0].privileged_skips==1&&cpus[0].count==2);
 tb.insns[0].cb(1,tb.insns[0].data);assert(cpus[1].count==0&&cpus[1].register_errors==1);
 bad_register=true;tb.insns[0].cb(0,tb.insns[0].data);bad_register=false;assert(cpus[0].register_errors==1);
 struct qemu_plugin_tb wrong={.count=1,.insns={{.pc=0x1000,.size=4,.bytes={0,0,0,0}}}};
 trans_callback(1,&wrong);assert(wrong.insns[0].cb&&atomic_load(&word_mismatches)==0);
 arm_start_ns=UINT64_MAX;reads=reg_reads;wrong.insns[0].cb(0,wrong.insns[0].data);assert(atomic_load(&word_mismatches)==0&&reg_reads==reads);
 arm_start_ns=saved_start;identity_mismatch=true;wrong.insns[0].cb(0,wrong.insns[0].data);identity_mismatch=false;assert(atomic_load(&word_mismatches)==0);
 wrong.insns[0].cb(0,wrong.insns[0].data);assert(atomic_load(&word_mismatches)==1);
 char*events=g_strdup_printf("%s/events.events",argv[1]);assert(fopen(events,"rb")==NULL);
 cpus[0].count=EVENT_CAPACITY;tb.insns[0].cb(0,tb.insns[0].data);assert(cpus[0].drops==1);cpus[0].count=2;
 exit_callback(1,NULL);
 f=fopen(events,"rb");assert(f);Event e[2];assert(fread(e,sizeof e,1,f)==1&&fgetc(f)==EOF);fclose(f);
 assert(e[0].pc==0x1000&&e[1].pc==0x1004&&e[0].ns<=e[1].ns);
 g_free(events);g_free(path);g_free(out);g_free(manifest_arg);
 puts("bounded Miles callback plugin fixture: PASS");return 0;
}
'''
flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','glib-2.0'],text=True))
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'fixture.c').write_text(source)
 subprocess.run(['clang','-std=c11','-g','-fsanitize=address,undefined','-I'+str(root/'include/qemu'),str(p/'fixture.c'),'-o',str(p/'fixture')]+flags,check=True)
 subprocess.run([str(p/'fixture'),d],check=True)
 meta=json.loads((p/'events.json').read_text());assert meta['flush_ok'] and meta['word_mismatches']==1 and meta['cpu'][0]['drops']==1 and meta['cpu'][0]['register_errors']==1 and meta['cpu'][1]['supported']==False
 assert meta['event_capacity_per_cpu']==262144 and meta['required_toc']==0x3a2000 and meta['arm_end_ns']-meta['arm_start_ns']==120000000000
 print('bounded arm/closed-window zero reads/TOC both phases/boot collision/armed collision/overflow/stopped flush checks: PASS')
