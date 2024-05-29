#include <stdint.h>
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include "common.h"

void kernel_body(int task_id, kernel_arg_t* __UNIFORM__ arg) {
	auto src0_ptr = reinterpret_cast<TYPE*>(arg->src0_addr);
	auto dst_ptr = reinterpret_cast<TYPE*>(arg->dst_addr);
	
	dst_ptr[0] = src0_ptr[0] + 1;
}

int main() {
	kernel_arg_t* arg = (kernel_arg_t*)csr_read(VX_CSR_MSCRATCH);
	vx_spawn_tasks(arg->num_tasks, (vx_spawn_tasks_cb)kernel_body, arg);
	return 0;
}
