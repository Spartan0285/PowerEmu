from pathlib import Path
import ast,subprocess,tempfile,shlex,json
old=ast.parse(Path('/tmp/pe9800/oct10-miles-callback-plugin-test.py').read_text());base=next(n.value.value for n in old.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='source' for t in n.targets))
stubs=base.split('int main(int argc')[0].replace('oct10-miles-callback-plugin.c','oct10-miles-produced-plugin.c')
stubs+='''
static bool mem_fail;static unsigned mem_reads;
bool qemu_plugin_read_memory_vaddr(uint64_t addr,GByteArray*b,size_t n){mem_reads++;if(mem_fail)return false;g_byte_array_set_size(b,n);if(n==4){b->data[0]=0;b->data[1]=0;b->data[2]=4;b->data[3]=0;}else for(size_t i=0;i<n;i++)b->data[i]=(i*17)^0xa5;return true;}
int main(int argc,char**argv){
 qemu_info_t info={.target_name="ppc64",.system_emulation=true,.system={.max_vcpus=2}};
 assert(qemu_plugin_install(1,&info,0,NULL)==0&&registrations==0);
 char*out=g_strdup_printf("out=%s/events",argv[1]);char*mf=g_strdup_printf("sites=%s/sites",argv[1]);char*path=g_strdup_printf("%s/sites",argv[1]);FILE*f=fopen(path,"w");assert(f);fputs("# verified-source-sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n1000 7c0802a6 1 0\\n1004 4e800020 1 1\\n",f);fclose(f);
 char*args[]={"enabled=1",out,mf,"arm-after-sec=0","window-sec=60","toc=3a2000","produced-chunks=1","fill-driver=123000","dest-range=200000:210000","stack-range=100000:140000"};
 assert(qemu_plugin_install(1,&info,7,args)==-1);
 char*cpath=g_strdup_printf("%s/control",argv[1]);char*carg=g_strdup_printf("control=%s",cpath);char*withcontrol[11];memcpy(withcontrol,args,sizeof(args));withcontrol[10]=carg;
 int fd=open(cpath,O_CREAT|O_WRONLY,0600);assert(fd>=0);assert(write(fd,"0",1)==1);close(fd);assert(qemu_plugin_install(1,&info,11,withcontrol)==-1);
 assert(truncate(cpath,32)==0);chmod(cpath,0644);assert(qemu_plugin_install(1,&info,11,withcontrol)==-1);chmod(cpath,0600);unlink(cpath);assert(symlink("sites",cpath)==0);assert(qemu_plugin_install(1,&info,11,withcontrol)==-1);unlink(cpath);g_free(carg);g_free(cpath);
 assert(qemu_plugin_install(1,&info,10,args)==0);
 init_callback(1,0);init_callback(1,1);
 Control page={0};control=&page;assert(!control_gate()&&atomic_load(&config_skips)==1);page=(Control){.version=1,.toc=0x3a2000,.driver=0x123000,.dest_lo=0x200000,.dest_hi=0x210000,.stack_lo=0x100000,.stack_hi=0x140000};atomic_store(&page.ready,0x50454d31);assert(control_gate()&&config_latched);page.driver+=4;assert(!control_gate()&&atomic_load(&config_errors)==1);page.driver-=4;control=NULL;

 Event e={.ns=now_ns(),.sp=0x123000,.lr=0x111111,.r3=0x123000,.r4=0x200000,.site=1};capture_fill(0,&e);
 Event r=e;r.phase=1;r.ns=now_ns();capture_fill(1,&r);assert(atomic_load(&chunk_claims)==1&&chunks[0].entry_cpu==0&&chunks[0].cpu==1);for(int i=0;i<1024;i++)assert(chunks[0].pcm[i]==(uint8_t)((i*17)^0xa5));assert(chunks[0].reserved>=r.ns);
 capture_fill(0,&e);capture_fill(1,&e);assert(atomic_load(&pair_failures)==1);capture_fill(1,&r);
 capture_fill(0,&e);Event overlap=e;overlap.sp+=4;capture_fill(1,&overlap);assert(atomic_load(&pair_failures)==2);capture_fill(0,&r);
 e.r4=dest_hi-1023;capture_fill(0,&e);assert(atomic_load(&pair_failures)==3);e.r4=0x200000;
 capture_fill(0,&e);mem_fail=true;capture_fill(1,&r);mem_fail=false;assert(atomic_load(&chunk_reads_failed)==1);
 atomic_flag_test_and_set(&capture_guard);capture_fill(0,&e);atomic_flag_clear(&capture_guard);assert(atomic_load(&pair_failures)==4);
 capture_fill(0,&e);atomic_store(&chunk_claims,CHUNK_CAPACITY);capture_fill(1,&r);assert(atomic_load(&chunk_drops)==1);atomic_store(&chunk_claims,1);
 capture_fill(0,&e); // unfinished must reject
 exit_callback(1,NULL);
 g_free(out);g_free(mf);g_free(path);puts("produced chunks: bounded crossCPU pairing/overlap/duplicate/read/overflow/unfinished PASS");return 0;
}
'''
flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','glib-2.0'],text=True))
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.c').write_text(stubs)
 subprocess.run(['clang','-std=c11','-g','-fsanitize=address,undefined','-I/Users/adam/Developer/poweremu-qemu/include/qemu',str(p/'test.c'),'-o',str(p/'test')]+flags,check=True)
 subprocess.run([str(p/'test'),d],check=True)
 m=json.loads((p/'events.chunks.json').read_text());assert m['records']==1 and m['unfinished']==1 and m['pair_failures']==4 and m['read_errors']==1 and m['drops']==1 and m['flush_ok'];assert (p/'events.chunks').stat().st_size==1088
 print('Sanitizer fixture PASS; does not establish TCG guest store visibility.')
