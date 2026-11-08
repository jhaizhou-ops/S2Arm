#define _POSIX_C_SOURCE 200112L
#include "s2a_avc.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "ih264_typedefs.h"
#include "iv.h"
#include "ivd.h"
#include "ih264d.h"

#define HEADER_MAX 512u
#define AU_MAX (64u * 1024u * 1024u)
#define DIM_MAX 8192u
_Static_assert(sizeof(s2a_avc_config) == 16, "config ABI");
_Static_assert(sizeof(s2a_avc_diag) == 56, "diag ABI");
_Static_assert(sizeof(s2a_avc_plane) == 32, "plane ABI requires 64-bit");
_Static_assert(sizeof(s2a_avc_planes_v1) == 120, "planes ABI");
_Static_assert(offsetof(s2a_avc_plane, capacity) == 8, "plane capacity ABI");

typedef struct allocation { void *data; struct allocation *next; } allocation;
typedef struct {
    uint32_t id, width, height, frame_bits, poc_type, poc_bits, refs;
    uint32_t chroma, bypass, direct;
} sequence;
typedef struct {
    uint32_t id, sps_id, entropy, pic_order, l0, l1, weighted, bipred;
    int32_t qp, chroma_qp, second_chroma_qp;
    uint32_t deblock, constrained, redundant, transform;
    uint8_t scales[8][64];
} picture;
struct s2a_avc {
    iv_obj_t *codec;
    allocation *allocations;
    uint8_t *buffer[3], *scratch, *rbsp;
    uint32_t capacity[3], scratch_capacity, rbsp_capacity;
    uint8_t sps[HEADER_MAX], pps[HEADER_MAX];
    uint32_t sps_len, pps_len, generation, token, width, height;
    int failed, available;
    s2a_avc_planes_v1 view;
};
#ifdef S2A_AVC_TESTING
static int64_t fail_after=-1;
static uint64_t live, allocation_calls;
void s2a_avc_test_fail_allocation(int64_t n) { fail_after=n; allocation_calls=0; }
uint64_t s2a_avc_test_live_allocations(void) { return live; }
uint64_t s2a_avc_test_allocation_calls(void) { return allocation_calls; }
static uint32_t fault;
void s2a_avc_test_fault(uint32_t value) { fault=value; }
#endif
static void *allocate(size_t size, size_t alignment) {
    void *p=NULL;
#ifdef S2A_AVC_TESTING
    allocation_calls++;
    if (fail_after == 0) return NULL;
    if (fail_after > 0) fail_after--;
#endif
    if (!size || !alignment || (alignment & (alignment-1))) return NULL;
    if (alignment < sizeof(void *)) alignment=sizeof(void *);
    if (posix_memalign(&p, alignment, size)) return NULL;
#ifdef S2A_AVC_TESTING
    live++;
#endif
    return p;
}
static void release(void *p) {
    if (!p) return;
#ifdef S2A_AVC_TESTING
    live--;
#endif
    free(p);
}
static void *codec_alloc(void *ctx, WORD32 alignment, WORD32 size) {
    s2a_avc *h=ctx;
    if (size<=0 || alignment<=0) return NULL;
    allocation *a=allocate(sizeof(*a), sizeof(void *));
    if (!a) return NULL;
    a->data=allocate((size_t)size, (size_t)alignment);
    if (!a->data) { release(a); return NULL; }
    a->next=h->allocations; h->allocations=a;
    return a->data;
}
static void codec_free(void *ctx, void *p) {
    s2a_avc *h=ctx;
    allocation **a=&h->allocations;
    while (*a) {
        if ((*a)->data==p) {
            allocation *old=*a; *a=old->next;
            release(old->data); release(old); return;
        }
        a=&(*a)->next;
    }
}
static int diag_init(s2a_avc_diag *d) {
    if (!d || d->abi_version!=S2A_AVC_ABI || d->struct_size!=sizeof(*d)) return 0;
    memset(d,0,sizeof(*d)); d->abi_version=S2A_AVC_ABI; d->struct_size=sizeof(*d); return 1;
}
static int fail(s2a_avc *h, s2a_avc_diag *d, int code, uint32_t stage) {
    if (h) { h->failed=1; h->available=0; }
    d->code=code; d->stage=stage; return code;
}
static int status(s2a_avc *h, s2a_avc_diag *d, int rc, uint32_t error, uint32_t stage) {
    d->ivd_status=rc; d->ivd_error=error; d->stage=stage;
    if (rc==IV_SUCCESS && !error) return 0;
    int code=S2A_AVC_BITSTREAM;
    if ((error & 255u)==IVD_MEM_ALLOC_FAILED) code=S2A_AVC_NOMEM;
    if (error & (1u << IVD_UNSUPPORTEDINPUT)) code=S2A_AVC_UNSUPPORTED;
    if ((error & 255u)==IVD_RES_CHANGED) code=S2A_AVC_RECONFIG;
    return fail(h,d,code,stage);
}
static int grow(uint8_t **p, uint32_t *capacity, uint32_t need) {
    if (need<=*capacity) return 1;
    uint8_t *next=allocate(need,64);
    if (!next) return 0;
    release(*p); *p=next; *capacity=need; return 1;
}
/* Bounded RBSP reader. No read, shift or Exp-Golomb operation can pass its end. */
typedef struct { const uint8_t *data; size_t bits, pos; int bad; } bits;
static uint32_t read_bits(bits *b, unsigned n) {
    if (n>32 || b->pos>b->bits || n>b->bits-b->pos) { b->bad=1; return 0; }
    uint32_t v=0;
    while(n--) { v=(v<<1)|((b->data[b->pos/8]>>(7-b->pos%8))&1); b->pos++; }
    return v;
}
static uint32_t ue(bits *b) {
    unsigned zeros=0;
    while (!b->bad && !read_bits(b,1)) { if (++zeros>30) { b->bad=1; return 0; } }
    return ((1u<<zeros)-1)+read_bits(b,zeros);
}
static int32_t se(bits *b) { uint32_t v=ue(b); return v&1 ? (int32_t)((v+1)/2) : -(int32_t)(v/2); }
static int rbsp(s2a_avc *h, const uint8_t *p, uint32_t n, bits *b) {
    if (!grow(&h->rbsp,&h->rbsp_capacity,n)) return S2A_AVC_NOMEM;
    uint32_t out=0, zeros=0;
    for(uint32_t i=0;i<n;i++) {
        uint8_t v=p[i];
        if (zeros>=2 && v==3) {
            if (i+1==n || p[i+1]>3) return S2A_AVC_BITSTREAM;
            zeros=0; continue;
        }
        h->rbsp[out++]=v;
        zeros=v==0 ? zeros+1 : 0;
    }
    *b=(bits){h->rbsp,(size_t)out*8,0,0}; return 0;
}
/* Annex B iterator accepts three/four-byte start codes and trailing_zero_8bits. */
static int nal(const uint8_t *p,uint32_t n,uint32_t *pos,const uint8_t **data,uint32_t *len) {
    uint32_t i=*pos, zeros=0;
    while(i<n && p[i]==0) { zeros++; i++; }
    if (zeros<2 || i>=n || p[i++]!=1) return 0;
    uint32_t start=i, end=n;
    for(uint32_t j=i;j<n;j++) {
        if (j+2<n && p[j]==0 && p[j+1]==0 && (p[j+2]==1 || (j+3<n && p[j+2]==0 && p[j+3]==1))) { end=j; break; }
    }
    *pos=end;
    while(end>start && p[end-1]==0) end--;
    if (end==start || (p[start]&0x80)) return 0;
    *data=p+start; *len=end-start; return 1;
}
static int single(s2a_avc *h,const uint8_t *p,uint32_t n,uint32_t type,bits *b) {
    uint32_t pos=0,len; const uint8_t *v;
    if (!p || n>HEADER_MAX || !nal(p,n,&pos,&v,&len) || pos!=n || (v[0]&31)!=type) return S2A_AVC_ARGUMENT;
    return rbsp(h,v+1,len-1,b);
}
static int parse_sps(bits *b,sequence *s) {
    memset(s,0,sizeof(*s));
    uint32_t profile=read_bits(b,8); read_bits(b,8); read_bits(b,8); s->id=ue(b);
    s->chroma=1;
    if(profile==100 || profile==110 || profile==122 || profile==244 || profile==44 || profile==83 || profile==86 || profile==118 || profile==128 || profile==138 || profile==139 || profile==134 || profile==135) {
        s->chroma=ue(b);
        if(s->chroma==3) read_bits(b,1);
        uint32_t depth_y=ue(b), depth_uv=ue(b); s->bypass=read_bits(b,1);
        if (s->chroma!=1 || depth_y || depth_uv || read_bits(b,1)) return S2A_AVC_UNSUPPORTED;
    } else if(profile!=66 && profile!=77 && profile!=88) return S2A_AVC_UNSUPPORTED;
    s->frame_bits=ue(b)+4; s->poc_type=ue(b);
    if(s->poc_type==0) s->poc_bits=ue(b)+4;
    else if(s->poc_type!=2) return S2A_AVC_UNSUPPORTED;
    s->refs=ue(b); if(read_bits(b,1)) return S2A_AVC_UNSUPPORTED;
    uint32_t w=ue(b), hh=ue(b);
    if(w>=DIM_MAX/16 || hh>=DIM_MAX/16 || s->frame_bits>16 || s->poc_bits>16 || s->refs>16 || s->id>31) return S2A_AVC_LIMIT;
    s->width=(w+1)*16; s->height=(hh+1)*16;
    if(!read_bits(b,1)) return S2A_AVC_UNSUPPORTED;
    s->direct=read_bits(b,1);
    if(read_bits(b,1)) { for(unsigned i=0;i<4;i++) ue(b); }
    read_bits(b,1); /* VUI does not affect the Nvdec coded surface. */
    return b->bad ? S2A_AVC_BITSTREAM : 0;
}
/* H.264 default scaling matrices in scan order (normative values; also in
 * the pinned AOSP Apache-2.0 decoder/ih264d_tables.c). */
static const uint8_t default4[2][16]={
 {6,13,13,20,20,20,28,28,28,28,32,32,32,37,37,42},
 {10,14,14,20,20,20,24,24,24,24,27,27,27,30,30,34}};
static const uint8_t default8[2][64]={
 {6,10,10,13,11,13,16,16,16,16,18,18,18,18,18,23,23,23,23,23,23,25,25,25,25,25,25,25,27,27,27,27,27,27,27,27,29,29,29,29,29,29,29,31,31,31,31,31,31,33,33,33,33,33,36,36,36,36,38,38,38,40,40,42},
 {9,13,13,15,13,15,17,17,17,17,19,19,19,19,19,21,21,21,21,21,21,22,22,22,22,22,22,22,24,24,24,24,24,24,24,24,25,25,25,25,25,25,25,27,27,27,27,27,27,28,28,28,28,28,30,30,30,30,32,32,32,33,33,35}};
static int scaling(bits *b,unsigned count,uint8_t *out,const uint8_t *defaults) {
    int last=8,next=8,use_default=0;
    for(unsigned j=0;j<count;j++) {
        if(next) { int32_t delta=se(b); if(delta < -128 || delta>127) return 0; next=(last+delta+256)%256; if(j==0 && next==0) use_default=1; }
        if(next) last=next;
        out[j]=(uint8_t)last;
    }
    if(use_default) memcpy(out,defaults,count);
    return !b->bad;
}
static int more_rbsp(bits *b) {
    bits copy=*b;
    if(read_bits(&copy,1)!=1) return 1;
    while(copy.pos<copy.bits) if(read_bits(&copy,1)) return 1;
    return 0;
}
static int parse_pps(bits *b,picture *p) {
    memset(p,0,sizeof(*p)); memset(p->scales,16,sizeof(p->scales));
    p->id=ue(b); p->sps_id=ue(b); p->entropy=read_bits(b,1); p->pic_order=read_bits(b,1);
    if(ue(b)) return S2A_AVC_UNSUPPORTED; /* FMO */
    p->l0=ue(b); p->l1=ue(b); p->weighted=read_bits(b,1); p->bipred=read_bits(b,2);
    p->qp=se(b); se(b); p->chroma_qp=se(b);
    p->deblock=read_bits(b,1); p->constrained=read_bits(b,1); p->redundant=read_bits(b,1);
    p->second_chroma_qp=p->chroma_qp;
    if(more_rbsp(b)) {
        p->transform=read_bits(b,1);
        if(read_bits(b,1)) {
            for(unsigned i=0;i<6+2*p->transform;i++) {
                const uint8_t *defaults=i<6 ? default4[i>=3] : default8[i-6];
                unsigned count=i<6 ? 16 : 64;
                if(read_bits(b,1)) { if(!scaling(b,count,p->scales[i],defaults)) b->bad=1; }
                else memcpy(p->scales[i],i>0 && i<6 && i!=3 ? p->scales[i-1] : defaults,count);
            }
        }
        p->second_chroma_qp=se(b);
    }
    if(p->id>255 || p->sps_id>31 || p->l0>31 || p->l1>31 || p->bipred>2 || p->qp < -26 || p->qp>25 || p->chroma_qp < -12 || p->chroma_qp>12 || p->second_chroma_qp < -12 || p->second_chroma_qp>12) return S2A_AVC_UNSUPPORTED;
    return b->bad ? S2A_AVC_BITSTREAM : 0;
}
static int same_sequence(const sequence *a,const sequence *b) {
    /* Level/profile, VUI, crop and original max_refs need not equal reconstructed
     * High/31/16. Syntax controlling slices and the coded surface must agree. */
    sequence x=*a,y=*b; x.refs=y.refs=0; return !memcmp(&x,&y,sizeof(x));
}
static int set_mode(s2a_avc *h,int header,s2a_avc_diag *d) {
    ivd_ctl_set_config_ip_t ip={0}; ivd_ctl_set_config_op_t op={0};
    ip.u4_size=sizeof(ip); ip.e_cmd=IVD_CMD_VIDEO_CTL; ip.e_sub_cmd=IVD_CMD_CTL_SETPARAMS;
    ip.e_vid_dec_mode=header ? IVD_DECODE_HEADER : IVD_DECODE_FRAME;
    ip.e_frm_skip_mode=IVD_SKIP_NONE; ip.e_frm_out_mode=IVD_DECODE_FRAME_OUT;
#ifdef S2A_AVC_MUTATE_DISPLAY_ORDER
    ip.e_frm_out_mode=IVD_DISPLAY_FRAME_OUT;
#endif
    op.u4_size=sizeof(op);
    int rc=ih264d_api_function(h->codec,&ip,&op);
    return status(h,d,rc,op.u4_error_code,S2A_AVC_CONFIG);
}
static int delete_codec(s2a_avc *h,s2a_avc_diag *d) {
    int result=0;
    if(h->codec) {
        ivd_delete_ip_t ip={sizeof(ip),IVD_CMD_DELETE}; ivd_delete_op_t op={0}; op.u4_size=sizeof(op);
        int rc=ih264d_api_function(h->codec,&ip,&op);
        result=status(h,d,rc,op.u4_error_code,S2A_AVC_DELETE); h->codec=NULL;
    }
    /* Covers failed/partial CREATE as well as any DELETE failure. */
    while(h->allocations) codec_free(h,h->allocations->data);
    for(unsigned i=0;i<3;i++) { release(h->buffer[i]); h->buffer[i]=NULL; h->capacity[i]=0; }
    h->available=0; return result;
}
static int new_codec(s2a_avc *h,s2a_avc_diag *d) {
    ih264d_create_ip_t ip={0}; ih264d_create_op_t op={0};
    ip.s_ivd_create_ip_t=(ivd_create_ip_t){sizeof(ip),IVD_CMD_CREATE,IV_YUV_420P,0,codec_alloc,codec_free,h};
    op.s_ivd_create_op_t.u4_size=sizeof(op);
    int rc=ih264d_api_function(NULL,&ip,&op);
    if(status(h,d,rc,op.s_ivd_create_op_t.u4_error_code,S2A_AVC_CREATE)) {
        while(h->allocations) codec_free(h,h->allocations->data);
        return d->code;
    }
    h->codec=op.s_ivd_create_op_t.pv_handle;
    if(!h->codec) return fail(h,d,S2A_AVC_BACKEND,S2A_AVC_CREATE);
    h->codec->u4_size=sizeof(iv_obj_t); h->codec->pv_fxns=(void *)ih264d_api_function;
    ih264d_ctl_set_num_cores_ip_t core={sizeof(core),IVD_CMD_VIDEO_CTL,(IVD_CONTROL_API_COMMAND_TYPE_T)IH264D_CMD_CTL_SET_NUM_CORES,1};
    ih264d_ctl_set_num_cores_op_t result={0}; result.u4_size=sizeof(result);
    rc=ih264d_api_function(h->codec,&core,&result);
    if(status(h,d,rc,result.u4_error_code,S2A_AVC_CONFIG)) return d->code;
    return set_mode(h,1,d);
}
static int call_decode(s2a_avc *h,uint8_t *data,uint32_t n,uint32_t token,ivd_video_decode_op_t *op,s2a_avc_diag *d,int header) {
    ivd_video_decode_ip_t ip={0}; memset(op,0,sizeof(*op)); op->u4_size=sizeof(*op);
    ip.u4_size=sizeof(ip); ip.e_cmd=IVD_CMD_VIDEO_DECODE; ip.u4_ts=token;
    ip.u4_num_Bytes=n; ip.pv_stream_buffer=data;
    if(!header) {
        ip.s_out_buffer.u4_num_bufs=3;
        for(unsigned i=0;i<3;i++) { ip.s_out_buffer.pu1_bufs[i]=h->buffer[i]; ip.s_out_buffer.u4_min_out_buf_size[i]=h->capacity[i]; }
    }
    int rc=ih264d_api_function(h->codec,&ip,op);
#ifdef S2A_AVC_TESTING
    if(!header && rc==IV_SUCCESS) {
        if(fault==1) op->u4_num_bytes_consumed=0;
        if(fault==2) op->u4_frame_decoded_flag=0;
        if(fault==3) op->u4_output_present=0;
        if(fault==4) op->u4_ts++;
        if(fault==5) op->s_disp_frm_buf.pv_y_buf=h->buffer[0]+h->capacity[0]-1;
        if(fault==6) op->s_disp_frm_buf.u4_v_strd++;
        if(fault==7) op->u4_error_code=1u<<IVD_CORRUPTEDDATA;
        if(fault==8) op->u4_pic_wd=UINT32_MAX;
    }
#endif
    d->consumed+=op->u4_num_bytes_consumed; d->decoded=op->u4_frame_decoded_flag;
    d->output=op->u4_output_present; d->output_token=op->u4_ts;
    return status(h,d,rc,op->u4_error_code,header?S2A_AVC_HEADER:S2A_AVC_DECODE);
}
static int headers(s2a_avc *h,const uint8_t *sps,uint32_t sn,const uint8_t *pps,uint32_t pn,s2a_avc_diag *d) {
    uint8_t input[HEADER_MAX*2]; memcpy(input,sps,sn); memcpy(input+sn,pps,pn);
    uint32_t pos=0,total=sn+pn;
    for(unsigned call=0;pos<total && call<4;call++) {
        ivd_video_decode_op_t op;
        if(call_decode(h,input+pos,total-pos,0,&op,d,1)) return d->code;
        if(!op.u4_num_bytes_consumed || op.u4_num_bytes_consumed>total-pos || op.u4_output_present || op.u4_frame_decoded_flag) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_HEADER);
        pos+=op.u4_num_bytes_consumed;
    }
    if(pos!=total) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_HEADER);
    ivd_ctl_getbufinfo_ip_t ip={sizeof(ip),IVD_CMD_VIDEO_CTL,IVD_CMD_CTL_GETBUFINFO};
    ivd_ctl_getbufinfo_op_t op={0}; op.u4_size=sizeof(op);
    int rc=ih264d_api_function(h->codec,&ip,&op);
    if(status(h,d,rc,op.u4_error_code,S2A_AVC_CONFIG)) return d->code;
    if(op.u4_min_num_out_bufs!=3) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_CONFIG);
    for(unsigned i=0;i<3;i++) {
        if(!op.u4_min_out_buf_size[i] || op.u4_min_out_buf_size[i]>AU_MAX) return fail(h,d,S2A_AVC_LIMIT,S2A_AVC_CONFIG);
        if(!grow(&h->buffer[i],&h->capacity[i],op.u4_min_out_buf_size[i])) return fail(h,d,S2A_AVC_NOMEM,S2A_AVC_CONFIG);
    }
    memcpy(h->sps,sps,sn); h->sps_len=sn; memcpy(h->pps,pps,pn); h->pps_len=pn;
    h->generation++; return set_mode(h,0,d);
}
/* Prepend bytes already present in scratch without losing the built AU.
 * Reallocation copies the old AU first; the existing destructive grow() must not
 * be used after access_unit() has filled the buffer. */
static int prepend(s2a_avc *h,const uint8_t *head,uint32_t n,uint32_t *bytes) {
    uint32_t need;
    if(__builtin_add_overflow(*bytes,n,&need)) return S2A_AVC_LIMIT;
    if(need>h->scratch_capacity) {
        uint8_t *next=allocate(need,64);
        if(!next) return S2A_AVC_NOMEM;
        memcpy(next+n,h->scratch,*bytes);
        release(h->scratch); h->scratch=next; h->scratch_capacity=need;
    } else memmove(h->scratch+n,h->scratch,*bytes);
    memcpy(h->scratch,head,n); *bytes=need; return 0;
}
/* Preflight all NALs before touching decoder state; retain one complete picture.
 * This also prevents a second VIDEO_DECODE from replacing an already output view. */
static int access_unit(s2a_avc *h,const uint8_t *au,uint32_t n,const sequence *s,const picture *p,uint32_t *out,int *idr) {
    uint32_t pos=0,used=0,slices=0,last_mb=0,identity[7]={0};
    *idr=0;
    while(pos<n) {
        const uint8_t *v; uint32_t len;
        if(!nal(au,n,&pos,&v,&len)) return S2A_AVC_BITSTREAM;
        uint32_t type=v[0]&31; bits b; int rc;
        if(type==7 || type==8) {
            if((rc=rbsp(h,v+1,len-1,&b))) return rc;
            if(type==7) { sequence raw; if((rc=parse_sps(&b,&raw))) return rc; if(!same_sequence(&raw,s)) return S2A_AVC_RECONFIG; }
            else { picture raw; if((rc=parse_pps(&b,&raw))) return rc; if(memcmp(&raw,p,sizeof(raw))) return S2A_AVC_RECONFIG; }
            continue;
        }
        if(type==1 || type==5) {
            if((rc=rbsp(h,v+1,len-1,&b))) return rc;
            uint32_t mb=ue(&b),slice_type=ue(&b),pps_id=ue(&b);
            uint32_t key[7]={read_bits(&b,s->frame_bits),type,v[0]>>5,0,0,0,slice_type};
            if(type==5) key[3]=ue(&b);
            if(s->poc_type==0) { key[4]=read_bits(&b,s->poc_bits); if(p->pic_order) key[5]=(uint32_t)se(&b); }
            if(p->redundant && ue(&b)) return S2A_AVC_UNSUPPORTED;
            if(b.bad || slice_type>9 || slice_type%5>2 || pps_id!=p->id || mb>=s->width/16*(s->height/16)) return S2A_AVC_BITSTREAM;
            if((!slices && mb!=0) || (slices && (mb<=last_mb || memcmp(identity,key,sizeof(key))))) return S2A_AVC_CONTRACT;
            memcpy(identity,key,sizeof(key)); last_mb=mb; slices++;
            if(type==5) *idr=1;
        } else if(type!=6 && type!=9 && type!=10 && type!=11 && type!=12) return S2A_AVC_UNSUPPORTED;
        if(used>h->scratch_capacity-4 || len>h->scratch_capacity-used-4) return S2A_AVC_LIMIT;
        h->scratch[used++]=0; h->scratch[used++]=0; h->scratch[used++]=0; h->scratch[used++]=1;
        memcpy(h->scratch+used,v,len); used+=len;
    }
    *out=used; return slices ? 0 : S2A_AVC_CONTRACT;
}
static int plane_view(s2a_avc *h,unsigned i,const void *ptr,uint32_t w,uint32_t ht,uint32_t stride) {
    uintptr_t start=(uintptr_t)h->buffer[i], at=(uintptr_t)ptr;
    if(!start || at<start || at-start>=h->capacity[i] || !w || !ht || stride<w) return 0;
    uint64_t capacity=h->capacity[i]-(at-start), need=(uint64_t)(ht-1)*stride+w;
    if(need>capacity) return 0;
    h->view.plane[i]=(s2a_avc_plane){ptr,capacity,w,ht,stride,0}; return 1;
}
const char *s2a_avc_provenance(void) { return S2A_AVC_PROVENANCE; }
int32_t s2a_avc_create(const s2a_avc_config *cfg,s2a_avc **out,s2a_avc_diag *d) {
    if(out) *out=NULL;
    if(!diag_init(d)) return S2A_AVC_ARGUMENT;
    if(!out || !cfg || cfg->abi_version!=S2A_AVC_ABI || cfg->struct_size!=sizeof(*cfg) || !cfg->width || !cfg->height || cfg->width>DIM_MAX || cfg->height>DIM_MAX) return fail(NULL,d,S2A_AVC_ARGUMENT,S2A_AVC_CREATE);
    s2a_avc *h=allocate(sizeof(*h),64);
    if(!h) return fail(NULL,d,S2A_AVC_NOMEM,S2A_AVC_CREATE);
    memset(h,0,sizeof(*h)); h->width=cfg->width; h->height=cfg->height;
    /* CREATE deferred until validated first headers. This keeps partial libavc
     * allocations under the same cleanup protocol as a failed first decode. */
    *out=h; return 0;
}
int32_t s2a_avc_decode(s2a_avc *h,const uint8_t *au,uint32_t n,const uint8_t *sps,uint32_t sn,const uint8_t *pps,uint32_t pn,uint32_t token,s2a_avc_diag *d) {
    if(h) h->available=0;
    if(!diag_init(d)) return S2A_AVC_ARGUMENT;
    if(!h) return fail(NULL,d,S2A_AVC_STATE,S2A_AVC_INPUT);
    d->input_token=token;
    if(h->failed) return fail(h,d,S2A_AVC_STATE,S2A_AVC_INPUT);
    if(!au || !n || n>AU_MAX || !sn || !pn || sn>HEADER_MAX || pn>HEADER_MAX || n>UINT32_MAX/2-8) return fail(h,d,S2A_AVC_ARGUMENT,S2A_AVC_INPUT);
    sequence s; picture p; bits b; int rc;
    if((rc=single(h,sps,sn,7,&b)) || (rc=parse_sps(&b,&s)) || (rc=single(h,pps,pn,8,&b)) || (rc=parse_pps(&b,&p))) return fail(h,d,rc,S2A_AVC_INPUT);
    if(p.sps_id!=s.id) return fail(h,d,S2A_AVC_BITSTREAM,S2A_AVC_INPUT);
    if(!grow(&h->scratch,&h->scratch_capacity,n*2+8)) return fail(h,d,S2A_AVC_NOMEM,S2A_AVC_INPUT);
    uint32_t bytes; int idr;
    if((rc=access_unit(h,au,n,&s,&p,&bytes,&idr))) return fail(h,d,rc,S2A_AVC_INPUT);
    int changed=h->sps_len && (sn!=h->sps_len || memcmp(sps,h->sps,sn));
    if((changed || !h->codec) && !idr) return fail(h,d,S2A_AVC_RECONFIG,S2A_AVC_INPUT);
    if(!h->codec && (s.width!=h->width || s.height!=h->height)) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_INPUT);
    if(changed) {
        if(delete_codec(h,d)) return d->code;
        h->sps_len=h->pps_len=0;
    }
    h->width=s.width; h->height=s.height; d->width=s.width; d->height=s.height;
    if(!h->codec) {
        if(new_codec(h,d) || headers(h,sps,sn,pps,pn,d)) return d->code;
    } else if(pn!=h->pps_len || memcmp(pps,h->pps,pn)) {
        /* PPS-only update: prefix it to this AU, without resubmitting SPS/resetting DPB. */
        if((rc=prepend(h,pps,pn,&bytes))) return fail(h,d,rc,S2A_AVC_INPUT);
        memcpy(h->pps,pps,pn); h->pps_len=pn;
    }
#ifdef S2A_AVC_MUTATE_RESEND_SPS
    if((rc=prepend(h,pps,pn,&bytes)) || (rc=prepend(h,sps,sn,&bytes))) return fail(h,d,rc,S2A_AVC_INPUT);
#endif
    d->consumed=0;
    ivd_video_decode_op_t op;
    if(call_decode(h,h->scratch,bytes,token,&op,d,0)) return d->code;
    if(op.u4_num_bytes_consumed>bytes || !op.u4_num_bytes_consumed || !op.u4_frame_decoded_flag || !op.u4_output_present || op.u4_ts!=token || !op.u4_progressive_frame_flag || op.e_output_format!=IV_YUV_420P) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_DECODE);
    /* libavc can stop immediately after the final slice. Only explicit non-VCL
     * Annex B suffixes may remain; never call VIDEO_DECODE again after output. */
    uint32_t tail=op.u4_num_bytes_consumed;
    while(tail<bytes) {
        const uint8_t *v; uint32_t len;
        if(!nal(h->scratch,bytes,&tail,&v,&len) || ((v[0]&31)!=6 && (v[0]&31)!=9 && (v[0]&31)!=10 && (v[0]&31)!=11 && (v[0]&31)!=12)) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_DECODE);
    }
    iv_yuv_buf_t *v=&op.s_disp_frm_buf;
    h->view=(s2a_avc_planes_v1){.abi_version=S2A_AVC_ABI,.struct_size=sizeof(h->view),.format=1,.progressive=1,.token=token,.generation=h->generation};
    if(op.u4_pic_wd!=s.width || op.u4_pic_ht!=s.height || v->u4_y_wd!=s.width || v->u4_y_ht!=s.height || v->u4_u_wd!=s.width/2 || v->u4_v_wd!=s.width/2 || v->u4_u_ht!=s.height/2 || v->u4_v_ht!=s.height/2 || v->u4_u_strd!=v->u4_v_strd ||
       !plane_view(h,0,v->pv_y_buf,v->u4_y_wd,v->u4_y_ht,v->u4_y_strd) || !plane_view(h,1,v->pv_u_buf,v->u4_u_wd,v->u4_u_ht,v->u4_u_strd) || !plane_view(h,2,v->pv_v_buf,v->u4_v_wd,v->u4_v_ht,v->u4_v_strd)) return fail(h,d,S2A_AVC_CONTRACT,S2A_AVC_PLANES);
#ifdef S2A_AVC_MUTATE_SWAP_UV
    s2a_avc_plane swapped=h->view.plane[1]; h->view.plane[1]=h->view.plane[2]; h->view.plane[2]=swapped;
#endif
    h->token=token; h->available=1; d->generation=h->generation; return 0;
}
int32_t s2a_avc_planes(s2a_avc *h,uint32_t token,s2a_avc_planes_v1 *out,s2a_avc_diag *d) {
    if(!diag_init(d)) return S2A_AVC_ARGUMENT;
    if(!out || out->abi_version!=S2A_AVC_ABI || out->struct_size!=sizeof(*out)) return fail(h,d,S2A_AVC_ARGUMENT,S2A_AVC_PLANES);
    memset(out,0,sizeof(*out));
    if(!h || h->failed || !h->available || h->token!=token) return fail(h,d,S2A_AVC_STATE,S2A_AVC_PLANES);
    *out=h->view; return 0;
}
int32_t s2a_avc_destroy(s2a_avc *h,s2a_avc_diag *d) {
    if(!diag_init(d)) return S2A_AVC_ARGUMENT;
    if(!h) return 0;
    int result=delete_codec(h,d); release(h->scratch); release(h->rbsp); release(h); return result;
}
