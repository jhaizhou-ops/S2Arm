// Allocation provenance is needed for terminal driver work: the stopped guest
// allocator cannot run, but a driver may allocate command-scoped scratch while
// waiting/destroying. Normal operation always delegates to the guest callbacks.
struct vk_allocation { void *pointer; size_t size; int terminal, retired; };
static struct vk_allocation *allocation_records;
static size_t allocation_count,allocation_capacity;
static size_t terminal_sorted_count;
static pthread_mutex_t allocation_mutex=PTHREAD_MUTEX_INITIALIZER;
static int allocation_compare(const void *a, const void *b) {
    uintptr_t x=(uintptr_t)((const struct vk_allocation *)a)->pointer;
    uintptr_t y=(uintptr_t)((const struct vk_allocation *)b)->pointer;
    return (x>y)-(x<y);
}
// Only after guest callbacks have drained. Preserve keys on removal, so the
// immutable prefix remains sorted; driver scratch allocations append to its tail.
static void allocation_prepare_terminal(void) {
    pthread_mutex_lock(&allocation_mutex);
    if(allocation_count)qsort(allocation_records,allocation_count,sizeof *allocation_records,allocation_compare);
    terminal_sorted_count=allocation_count;
    pthread_mutex_unlock(&allocation_mutex);
}
static void allocation_remember(void *p,size_t size,int terminal){
    if(!p)return;
    pthread_mutex_lock(&allocation_mutex);
    if(allocation_count==allocation_capacity){
        size_t n=allocation_capacity?allocation_capacity*2:256;
        void *records=n<=1048576?realloc(allocation_records,n*sizeof *allocation_records):NULL;
        if(!records){pthread_mutex_unlock(&allocation_mutex);fatal("Vulkan allocation provenance capacity");}
        allocation_records=records;allocation_capacity=n;
    }
    allocation_records[allocation_count++]=(struct vk_allocation){p,size,terminal,0};
    pthread_mutex_unlock(&allocation_mutex);
}
static int allocation_find(void *p,struct vk_allocation *out,int remove){
    pthread_mutex_lock(&allocation_mutex);int found=0;
    // New terminal scratch (and all allocations before terminal preparation).
    for(size_t j=allocation_count;j>terminal_sorted_count;j--)if(allocation_records[j-1].pointer==p){
        if(out)*out=allocation_records[j-1];
        if(remove)allocation_records[j-1]=allocation_records[--allocation_count];
        found=1;break;
    }
    if(!found && terminal_sorted_count){
        size_t lo=0,hi=terminal_sorted_count;
        while(lo<hi){size_t mid=lo+(hi-lo)/2;
            if((uintptr_t)allocation_records[mid].pointer<(uintptr_t)p)lo=mid+1;else hi=mid;
        }
        if(lo<terminal_sorted_count && allocation_records[lo].pointer==p && !allocation_records[lo].retired){
            if(out)*out=allocation_records[lo];
            if(remove)allocation_records[lo].retired=1;
            found=1;
        }
    }
    pthread_mutex_unlock(&allocation_mutex);return found;
}
static void *terminal_allocate(size_t size,size_t alignment){
    if(alignment<sizeof(void *))alignment=sizeof(void *);
    if(alignment&(alignment-1))return NULL;
    void *p=NULL;if(posix_memalign(&p,alignment,size?size:1))return NULL;
    allocation_remember(p,size,1);return p;
}
static void terminal_free(void *p){
    if(!p)return;
    struct vk_allocation record;
    if(!allocation_find(p,&record,1)){
        // Unknown provenance is a bookkeeping error, never permission to free.
        fprintf(stderr,"[vk-direct] 终止清场：未知来源释放 %p\n",p);
        fatal("Vulkan terminal free has unknown provenance");
    }
    if(record.terminal)free(p);
    else atomic_fetch_add(&quarantined_frees,1); // guest heap stays mapped until _exit
}
static void *terminal_reallocate(void *p,size_t size,size_t alignment){
    if(!p)return size?terminal_allocate(size,alignment):NULL;
    struct vk_allocation old;
    if(!allocation_find(p,&old,0))fatal("Vulkan terminal realloc has unknown provenance");
    if(!size){terminal_free(p);return NULL;}
    void *next=terminal_allocate(size,alignment);if(!next)return NULL;
    memcpy(next,p,old.size<size?old.size:size);terminal_free(p);return next;
}
static size_t terminal_scratch_left(void){
    pthread_mutex_lock(&allocation_mutex);size_t n=0;
    for(size_t j=0;j<allocation_count;j++)if(allocation_records[j].terminal && !allocation_records[j].retired)n++;
    pthread_mutex_unlock(&allocation_mutex);return n;
}
