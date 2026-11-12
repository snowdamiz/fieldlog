#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef int32_t (*surface_callback)(int64_t,int32_t,const uint8_t*,intptr_t,const uint8_t*,intptr_t,const uint8_t*,intptr_t);
extern int32_t mixer_public_android_submit(int64_t,int32_t,const uint8_t*,intptr_t,const uint8_t*,intptr_t,const uint8_t*,intptr_t,const uint8_t*,intptr_t,surface_callback);
typedef int32_t (*photo_callback)(int64_t,const uint8_t*,intptr_t);
extern int32_t fieldlog_android_photo_submit(int64_t,const uint8_t*,intptr_t,int32_t,const uint8_t*,intptr_t,photo_callback);
extern int32_t mixer_public_android_poll(int64_t);
typedef struct Context { int64_t id; jobject receiver; uint8_t *directory; intptr_t directory_n; int busy, failed; struct Context *next; } Context;
static Context *contexts;
static int64_t next_id;
static _Thread_local JNIEnv *pump_env;
static Context *find(int64_t id) { for(Context *p=contexts;p;p=p->next) if(p->id==id) return p; return NULL; }
static jbyteArray bytes(JNIEnv *e,const uint8_t *p,intptr_t n) {
    if(n<0||n>1048576||(n&&!p)) return NULL;
    jbyteArray a=(*e)->NewByteArray(e,(jsize)n);
    if(a&&n) (*e)->SetByteArrayRegion(e,a,0,(jsize)n,(const jbyte*)p);
    return a;
}
static int32_t surface(int64_t id,int32_t op,const uint8_t *o,intptr_t on,const uint8_t *p,intptr_t pn,const uint8_t *a,intptr_t an) {
    JNIEnv *e=pump_env; Context *c=find(id); if(!e||!c||!c->busy) return 1;
    jclass type=(*e)->GetObjectClass(e,c->receiver); if(!type) return 1;
    jmethodID method=(*e)->GetMethodID(e,type,"surface","(JI[B[B[B)I");
    jbyteArray owner=bytes(e,o,on),packet=bytes(e,p,pn),appearance=bytes(e,a,an);
    jint result=1;
    if(method&&owner&&packet&&appearance&&!(*e)->ExceptionCheck(e)) result=(*e)->CallIntMethod(e,c->receiver,method,(jlong)id,(jint)op,owner,packet,appearance);
    if((*e)->ExceptionCheck(e)) { (*e)->ExceptionClear(e); result=1; }
    if(owner) (*e)->DeleteLocalRef(e,owner);
    if(packet) (*e)->DeleteLocalRef(e,packet);
    if(appearance) (*e)->DeleteLocalRef(e,appearance);
    (*e)->DeleteLocalRef(e,type); return result;
}
static int execute(JNIEnv *e,Context *c,int op,const uint8_t *profile,intptr_t profile_n,const uint8_t *owner,intptr_t owner_n,const uint8_t *event,intptr_t event_n) {
    if(!c||c->busy||pump_env||(c->failed&&op!=2)) return 1;
    c->busy=1;
    int result=mixer_public_android_submit(c->id,op,profile,profile_n,op==0?c->directory:NULL,op==0?c->directory_n:0,owner,owner_n,event,event_n,surface);
    if(result==0) {
        pump_env=e; int status=0;
        for(int i=0;i<1000&&status==0;i++) status=mixer_public_android_poll(c->id);
        pump_env=NULL; result=status==1?0:1;
        if(status==0) c->failed=1; /* Unknown queued work: retain, never retry. */
    }
    c->busy=0; return result;
}
static int32_t photo_request(int64_t id,const uint8_t *request,intptr_t count) {
    JNIEnv *e=pump_env; Context *c=find(id); if(!e||!c||!c->busy||count!=36) return 1;
    jclass type=(*e)->GetObjectClass(e,c->receiver); if(!type) return 1;
    jmethodID method=(*e)->GetMethodID(e,type,"photoRequest","(J[B)I");
    jbyteArray token=bytes(e,request,count); jint result=1;
    if(method&&token&&!(*e)->ExceptionCheck(e)) result=(*e)->CallIntMethod(e,c->receiver,method,(jlong)id,token);
    if((*e)->ExceptionCheck(e)) { (*e)->ExceptionClear(e); result=1; }
    if(token) (*e)->DeleteLocalRef(e,token);
    (*e)->DeleteLocalRef(e,type); return result;
}
static int execute_photo(JNIEnv *e,Context *c,const uint8_t *request,intptr_t rn,int code,const uint8_t *data,intptr_t dn) {
    if(!c||c->busy||c->failed||pump_env) return 1;
    c->busy=1;
    int result=fieldlog_android_photo_submit(c->id,request,rn,code,data,dn,photo_request);
    if(result==0) {
        pump_env=e; int status=0;
        for(int i=0;i<1000&&status==0;i++) status=mixer_public_android_poll(c->id);
        pump_env=NULL; result=status==1?0:1;
        if(status==0) c->failed=1;
    }
    c->busy=0; return result;
}
static jint photo_host(JNIEnv *e,jclass ignored,jlong id,jbyteArray request,jint code,jbyteArray data) {
    (void)ignored; Context *c=find(id); if(!c||!request||!data||code<0||code>5) return 1;
    jsize rn=(*e)->GetArrayLength(e,request),dn=(*e)->GetArrayLength(e,data);
    if(rn!=36||dn<0||dn>6291456||(code==5?dn<3:dn!=0)) return 1;
    jbyte *r=(*e)->GetByteArrayElements(e,request,NULL); if(!r) return 1;
    jbyte *d=(*e)->GetByteArrayElements(e,data,NULL); if(!d) { (*e)->ReleaseByteArrayElements(e,request,r,JNI_ABORT); return 1; }
    int result=execute_photo(e,c,(const uint8_t*)r,rn,code,(const uint8_t*)d,dn);
    (*e)->ReleaseByteArrayElements(e,data,d,JNI_ABORT); (*e)->ReleaseByteArrayElements(e,request,r,JNI_ABORT); return result;
}
typedef int32_t (*report_callback)(int64_t,const uint8_t*,intptr_t,const uint8_t*,intptr_t,intptr_t,int32_t);
extern int32_t fieldlog_android_report_submit(int64_t,const uint8_t*,intptr_t,int32_t,report_callback);
static int32_t report_request(int64_t id,const uint8_t *request,intptr_t rn,const uint8_t *path,intptr_t pn,intptr_t size,int32_t fd) {
    JNIEnv *e=pump_env; Context *c=find(id);
    if(!e||!c||!c->busy||!request||rn!=36||!path||pn<=0||pn>4096||size<=0||size>37748736||fd<0) return 1;
    jclass type=(*e)->GetObjectClass(e,c->receiver); if(!type) return 1;
    jmethodID method=(*e)->GetMethodID(e,type,"reportRequest","(J[B[BJI)I");
    jbyteArray token=bytes(e,request,rn),file=bytes(e,path,pn); jint result=1;
    if(method&&token&&file&&!(*e)->ExceptionCheck(e)) result=(*e)->CallIntMethod(e,c->receiver,method,(jlong)id,token,file,(jlong)size,(jint)fd);
    if((*e)->ExceptionCheck(e)) { (*e)->ExceptionClear(e); result=1; }
    if(token) (*e)->DeleteLocalRef(e,token);
    if(file) (*e)->DeleteLocalRef(e,file);
    (*e)->DeleteLocalRef(e,type); return result;
}
static int execute_report(JNIEnv *e,Context *c,const uint8_t *request,intptr_t rn,int code) {
    if(!c||c->busy||c->failed||pump_env) return 1;
    c->busy=1;
    int result=fieldlog_android_report_submit(c->id,request,rn,code,report_request);
    if(result==0) {
        pump_env=e; int status=0;
        for(int i=0;i<1000&&status==0;i++) status=mixer_public_android_poll(c->id);
        pump_env=NULL; result=status==1?0:1;
        if(status==0) c->failed=1;
    }
    c->busy=0; return result;
}
static jint report_host(JNIEnv *e,jclass ignored,jlong id,jbyteArray request,jint code) {
    (void)ignored; Context *c=find(id); if(!c||!request||code<0||code>2||(*e)->GetArrayLength(e,request)!=36) return 1;
    jbyte *token=(*e)->GetByteArrayElements(e,request,NULL); if(!token) return 1;
    int result=execute_report(e,c,(const uint8_t*)token,36,code);
    (*e)->ReleaseByteArrayElements(e,request,token,JNI_ABORT); return result;
}
static jlong open_host(JNIEnv *e,jclass ignored,jobject receiver,jstring profile,jbyteArray directory) {
    (void)ignored; if(!receiver||!profile||!directory||next_id==INT64_MAX) return 0;
    int count=0; for(Context *p=contexts;p;p=p->next) count++;
    if(count>=16) return 0;
    jsize dn=(*e)->GetArrayLength(e,directory); if(dn<=0||dn>4096) return 0;
    jsize n=(*e)->GetStringUTFLength(e,profile); if(n<=0||n>64) return 0;
    const char *text=(*e)->GetStringUTFChars(e,profile,NULL); if(!text) return 0;
    if(n!=(jsize)strlen("MEASURED_MULTILINE_LONG_NOTES_V4")||memcmp(text,"MEASURED_MULTILINE_LONG_NOTES_V4",(size_t)n)!=0) { (*e)->ReleaseStringUTFChars(e,profile,text); return 0; }
    Context *c=calloc(1,sizeof(*c)); if(!c) { (*e)->ReleaseStringUTFChars(e,profile,text); return 0; }
    c->id=++next_id; c->receiver=(*e)->NewGlobalRef(e,receiver);
    if(!c->receiver) { free(c); (*e)->ReleaseStringUTFChars(e,profile,text); return 0; }
    c->directory=malloc((size_t)dn);
    if(!c->directory) { (*e)->DeleteGlobalRef(e,c->receiver); free(c); (*e)->ReleaseStringUTFChars(e,profile,text); return 0; }
    (*e)->GetByteArrayRegion(e,directory,0,dn,(jbyte*)c->directory);
    if((*e)->ExceptionCheck(e)) { free(c->directory); (*e)->DeleteGlobalRef(e,c->receiver); free(c); (*e)->ReleaseStringUTFChars(e,profile,text); return 0; }
    c->directory_n=dn;
    c->next=contexts; contexts=c;
    int result=execute(e,c,0,(const uint8_t*)text,n,NULL,0,NULL,0);
    (*e)->ReleaseStringUTFChars(e,profile,text);
    if(result) { c->failed=1; return 0; } /* Keep uncertain activation cleanup visible. */
    return c->id;
}
static jint event_host(JNIEnv *e,jclass ignored,jlong id,jbyteArray owner,jbyteArray event) {
    (void)ignored; Context *c=find(id); if(!c||!owner||!event) return 1;
    jsize on=(*e)->GetArrayLength(e,owner),en=(*e)->GetArrayLength(e,event);
    if(on<=0||on>64||en<=0||en>1048576) return 1;
    jbyte *o=(*e)->GetByteArrayElements(e,owner,NULL); if(!o) return 1;
    jbyte *v=(*e)->GetByteArrayElements(e,event,NULL); if(!v) { (*e)->ReleaseByteArrayElements(e,owner,o,JNI_ABORT); return 1; }
    int result=execute(e,c,1,NULL,0,(const uint8_t*)o,on,(const uint8_t*)v,en);
    (*e)->ReleaseByteArrayElements(e,event,v,JNI_ABORT); (*e)->ReleaseByteArrayElements(e,owner,o,JNI_ABORT);
    if(result==0) result=execute_photo(e,c,NULL,0,-1,NULL,0);
    if(result==0) result=execute_report(e,c,NULL,0,-1);
    return result;
}
static jint close_host(JNIEnv *e,jclass ignored,jlong id) {
    (void)ignored; Context *c=find(id); if(!c||c->failed) return 1;
    if(execute(e,c,2,NULL,0,NULL,0,NULL,0)) { c->failed=1; return 1; }
    Context **link=&contexts; while(*link!=c) link=&(*link)->next;
    *link=c->next; (*e)->DeleteGlobalRef(e,c->receiver); free(c->directory); free(c); return 0;
}
/* Package-specific names are supplied at build time without JNI name escaping.
   RegisterNatives requires the exact generated PublicBridge class. */
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm,void *reserved) {
    (void)reserved; JNIEnv *e=NULL;
    if((*vm)->GetEnv(vm,(void**)&e,JNI_VERSION_1_6)!=JNI_OK) return JNI_ERR;
    jclass type=(*e)->FindClass(e,"dev/fieldlog/generatedr90/androidhost/PublicBridge"); if(!type) return JNI_ERR;
    JNINativeMethod methods[]={{"openNative","(Ldev/fieldlog/generatedr90/androidhost/PublicActivity;Ljava/lang/String;[B)J",(void*)open_host},
        {"eventNative","(J[B[B)I",(void*)event_host},{"closeNative","(J)I",(void*)close_host},
        {"photoNative","(J[BI[B)I",(void*)photo_host},{"reportNative","(J[BI)I",(void*)report_host}};
    jint status=(*e)->RegisterNatives(e,type,methods,5); (*e)->DeleteLocalRef(e,type);
    return status==0?JNI_VERSION_1_6:JNI_ERR;
}
