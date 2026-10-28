// Read-only diagnostic: process credentials, audit identities and bootstrap metadata.
// No device access, permission changes or mount operations.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <bsm/audit.h>

static int seen[65536], nseen;
static int seen_pid(int pid) { for(int i=0;i<nseen;i++) if(seen[i]==pid)return 1; return 0; }
static void describe(int pid, const char *role) {
    struct proc_bsdinfo p={0}; char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof(p))!=sizeof(p)) return;
    proc_pidpath(pid,path,sizeof(path));
    struct auditpinfo_addr audit={0}; audit.ap_pid=pid; errno=0;
    int result=auditon(A_GETPINFO_ADDR,&audit,sizeof(audit)); int error=result<0?errno:0;
    printf("{\"role\":\"%s\",\"pid\":%d,\"ppid\":%u,\"ruid\":%u,\"euid\":%u,\"rgid\":%u,\"egid\":%u,\"saved_uid\":%u,\"audit_errno\":%d,\"audit_uid\":%d,\"audit_session\":%d,\"path\":\"%s\"}\n",role,pid,p.pbi_ppid,p.pbi_ruid,p.pbi_uid,p.pbi_rgid,p.pbi_gid,p.pbi_svuid,error,result==0?(int)audit.ap_auid:-1,result==0?(int)audit.ap_asid:-1,path);
    fflush(stdout);
}
static void command(const char *verb, int pid) {
    printf("BEGIN launchctl %s pid=%d\n",verb,pid); fflush(stdout);
    int channel[2]; if(pipe(channel)) return;
    pid_t child=fork();
    if(child==0) {
        close(channel[0]); dup2(channel[1],STDOUT_FILENO); dup2(channel[1],STDERR_FILENO); close(channel[1]);
        char number[32];snprintf(number,sizeof(number),"%d",pid);
        if(!strcmp(verb,"procinfo")) execl("/bin/launchctl","launchctl",verb,number,(char*)NULL);
        else execl("/bin/launchctl","launchctl",verb,(char*)NULL);
        _exit(127);
    }
    close(channel[1]);
    FILE *reader=fdopen(channel[0],"r");char *line=NULL;size_t size=0;
    if(reader) {
        while(getline(&line,&size,reader)>0) {
            // Keep only requested identity/session metadata. Never emit arguments,
            // environment vectors, entitlements or unrelated process details.
            if(strstr(line,"program path =") || strstr(line,"session id =") ||
               strstr(line,"\tuid =") || strstr(line,"\truid =") || strstr(line,"\tgid =") ||
               strstr(line,"\trgid =") || strstr(line,"\tasid =") || strstr(line,"\tdomain =") ||
               strstr(line,"Could not print Mach info") || !strcmp(line,"audit info\n")) fputs(line,stdout);
        }
        free(line);fclose(reader);
    }
    int status=0;if(child>0)waitpid(child,&status,0);
    printf("END launchctl %s status=%d\n",verb,status);fflush(stdout);
}
static const char *role_for(const char *path) {
    if(!strcmp(path,"/Library/PrivilegedHelperTools/local.NTFSEditor.mount/NTFSEditorMountHelper")) return "production-helper";
    if(!strcmp(path,"/Library/PrivilegedHelperTools/local.NTFSEditor.mount/engine/bin/ntfs-3g")) return "production-engine";
    if(!strcmp(path,"/usr/bin/osascript")) return "authorization-client";
    if(!strcmp(path,"/sbin/mount")) return "apple-mount-command";
    if(!strcmp(path,"/usr/libexec/fskitd")) return "apple-fskitd";
    if(!strcmp(path,"/usr/libexec/fskit_helper")) return "apple-fskit-helper";
    if(!strcmp(path,"/usr/libexec/fskit_agent")) return "apple-fskit-agent";
    if(strstr(path,"/macfuse.app/") || strstr(path,"/io.macfuse.app."))return "macfuse-service-or-extension";
    if(!strcmp(path,"/Users/manfredsun/Desktop/Antigravity/NTFS Editor/Build/NTFS Editor.app/Contents/MacOS/NTFS Editor"))return "production-app";
    if(strstr(path,"/.build/integration-mount")) return "integration-client";
    return NULL;
}
int main(int argc,char **argv) {
    describe(getpid(),"diagnostic-self");describe(getppid(),"diagnostic-parent");
    command("manageruid",0);command("managername",0);
    if(argc<2 || (strcmp(argv[1],"--watch") && strcmp(argv[1],"--watch-fast")))return 0;
    int fast=!strcmp(argv[1],"--watch-fast");
    time_t deadline=time(NULL)+120, finished=0; int found_helper=0;
    while(time(NULL)<deadline) {
        int pids[65536];int count=proc_listallpids(pids,sizeof(pids));int live_helper=0;
        if(count>65536)count=65536;
        for(int i=0;i<count;i++) {
            char path[PROC_PIDPATHINFO_MAXSIZE]={0};if(proc_pidpath(pids[i],path,sizeof(path))<=0)continue;
            const char *role=role_for(path);if(!role)continue;
            if(!strcmp(role,"production-helper") || !strcmp(role,"production-engine"))live_helper=found_helper=1;
            if(!seen_pid(pids[i]) && nseen<65536) {
                seen[nseen++]=pids[i];describe(pids[i],role);
                if(geteuid()==0 && !fast)command("procinfo",pids[i]);
                if(!strcmp(role,"production-helper")) {struct proc_bsdinfo p={0};if(proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&p,sizeof(p))==sizeof(p))describe(p.pbi_ppid,"helper-parent");}
            }
        }
        if(found_helper && !live_helper) {if(!finished)finished=time(NULL);if(time(NULL)-finished>=3)break;}else finished=0;
        usleep(fast ? 1000 : 100000);
    }
    puts("DIAGNOSTIC_FINISHED");return 0;
}
