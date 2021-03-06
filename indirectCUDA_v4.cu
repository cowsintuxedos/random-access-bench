//
// Author     :  matto@xilinx 14JAN2018, alai@xilinx 25JULY2018
// Filename   :  indirectTest_onlyGPU.cu
// Description:  Cuda random access benchmark example based on indirect.c by gswart/skchavan@oracle
//
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <utime.h>
#include <sys/time.h>

#include <cuda_runtime.h>
#include <helper_cuda.h>
#include <helper_functions.h>
#include <curand.h>
#include <curand_kernel.h>

//#define DEBUG
#define CPU_BENCH
#define NOCUDA

#define MEM_LOGN 28
//#define GATHER2

#define FULLMEM
//#define VERIF

// README
// USE THIS TO CHANGE THE SIZE OF THE STRUCTURE
#define INPUT_SIZE 32  // make sure it's divisible by 8

// max array sizes for certain inputs; going over will cause program to crash
enum {
#if INPUT_SIZE>128  // 512 B, max 19
  rows = 1U << 22,
  array = 1U << 22,
#elif INPUT_SIZE>32 // 128 B, max 21
  rows = 1U << 16,
  array = 1U << 16,
#elif INPUT_SIZE>0  // 32 B, max 23
  rows = 1U << 26,
  array = 1U << 26,
#endif
  groups = 1U << 10,
  segment_bits = 12,
  segments = array / (1U << segment_bits)
};

// each Row stucture is 8 bytes
struct Row {
  unsigned int measure;
  unsigned int group;
};

// stores an array of rows to act as a sized byte container
// i.e. struct Row rows_arr[128/8] is 128 bytes
struct Row16 {
  // [input size/size of Row]
  struct Row rows_arr[INPUT_SIZE/8];
};

struct BigRow {
  //unsigned int ints[INPUT_SIZE/4];
  uint64_t ints[INPUT_SIZE/8];
};

struct String {
  char str[INPUT_SIZE];
};

#ifdef NOCUDA
// ikimasu
__device__ struct BigRow d_A[array];
__device__ unsigned int d_in[rows];
__device__ struct BigRow d_out[rows];
//__device__ unsigned long long d_agg1[groups];
//__device__ unsigned long long d_agg2[groups];
//__device__ struct Row d_out2[rows];
//__device__ struct Row * d_B[segments];

__device__ struct Row16 dd_A[array]; // random array
__device__ struct String dd_B[array]; // string array
__device__ unsigned int dd_in[rows];
__device__ struct Row16 dd_out[rows];
__device__ struct Row16 dd_out2[rows];

__device__ unsigned long input_size_d = (unsigned long)sizeof(struct BigRow); // device input size
__device__ unsigned long row_size_d = (unsigned long)sizeof(struct Row);

unsigned long input_size_h = (unsigned long)sizeof(struct BigRow); // host input size
unsigned long row_size_h = (unsigned long)sizeof(struct Row);

/*
struct Row16 A[array];
unsigned int in[rows];
struct Row16 out[rows];*/

struct BigRow A[array];
unsigned int in[rows];
struct BigRow out[rows];

static void init()
{
  printf("Initializing data structures. (CPU)\n");

  // Random fill indirection array A
  unsigned int i, j;
  for (i = 0; i < array; i++) {
    for (j = 0; j < (INPUT_SIZE/8); j++) {
	    //A[i].rows_arr[j].measure = rand() % array;
      //A[i].rows_arr[j].group = rand() % groups;
      A[i].ints[j] = rand() % array;
    }
  }

  for (i = 0; i < rows; i++) {
    for (j = 0; j < (INPUT_SIZE/8); j++) {
      in[i] = rand() % array;
    }
  }
  checkCudaErrors(cudaMemcpyToSymbol(d_A, A, sizeof(A)));
  checkCudaErrors(cudaMemcpyToSymbol(d_in, in, sizeof(in)));
  checkCudaErrors(cudaMemcpyToSymbol(d_out, out, sizeof(out)));
}

// initialize the GPU arrays
__global__ void d_init()
{
    printf("Initializing data structures.\n");
    int tId = threadIdx.x + (blockIdx.x * blockDim.x);
    curandState state;
    curand_init((unsigned long long)clock() + tId, 0, 0, &state);
    //printf("Size of word: %lu bytes\n", (unsigned long)sizeof(dd_A[0].str));
    //printf("Size of word container: %lu bytes\n", (unsigned long)sizeof(dd_A[0]));

    // Random fill indirection array A
    unsigned int i;
    unsigned int j;
    printf("Randomly filling array A.\n");
    for (i = 0; i < array; i++) {
      for (j = 0; j < (input_size_d/row_size_d); j++) {
        dd_A[i].rows_arr[j].measure = curand_uniform(&state) * array;
        dd_A[i].rows_arr[j].group = curand_uniform(&state) * groups;
        //printf("dd_A[%d][%d] - %d\n",i,j,dd_A[i].rows_arr[j].measure);
      }
    }

    // Random fill input
    printf("Randomly filling input array.\n");
    for (i = 0; i < rows; i++) {
      dd_in[i] = curand_uniform(&state) * array;
      //printf("dd_in[%d] - %d\n",i,dd_in[i]);
    }
    printf("Successfully initialized input array.\n");

    // generate random array for benching writes
    //for (i = 0; i < rows; i++) {
    //  dd_out[i] = dd_out2[dd_in[i]];
    //}
    //temp2 = dd_A[0];
}

// bench gathers
__global__ void d_bench()
{
  unsigned i;
  for (i = 0; i < rows; i++) {
    d_out[i] = d_A[d_in[i]];
  }
}

// read / write methods //
// bench random reads
__global__ void d_bench_read_random()
{
  unsigned i;
  struct BigRow temp;
  for (i = 0; i < rows; i++) {
    temp = d_A[d_in[i]];
    //d_A[d_in[i]].ints[0] += 0;
  }
}

// bench random writes
__global__ void d_bench_write_random()
{
  unsigned i;
  struct BigRow temp = d_A[d_in[0]];
  for (i = 0; i < rows; i++) {
    d_out[d_in[i]] = temp;
  }
}

#endif // !1

#ifdef VERIF
static __global__ void
d_check(size_t n, benchtype *t)
{
	for (i = 0; i < groups; i++) {
		if (d_agg1[i] != d_agg2[i]) printf("Agg doesn't match: %d\n", i);
	}
}
#endif // VERIF

// convert from B/ms to MB/s for print output
float convert_to_MBs(float ms) {
  return ((rows*input_size_h)/(ms/1000)/1000000.f); // 1048576 = 1024^2, i.e. bytes to MB
}

float convert_to_Ts(float ms) {
  return (rows/(ms/1000))/1000000.f; // 
}

// calculate mean of array
float mean(float* input_arr) {
  float sum = 0;
  for (unsigned i = 0; i < rows; i++)
    sum += input_arr[i];
  return sum/rows;
}

// start test
#define DEFAULT_LOGN 20
#define POLY 0x0000000000000007ULL

union benchtype {
  uint64_t u64;
  uint2 u32;
};

static __constant__ uint64_t c_m2[64];
static __device__ uint32_t d_error[1];

static __global__ void
d_init1(size_t n, benchtype *t)
{
  for (ptrdiff_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    t[i].u64 = i;
  }
}

static __device__ uint64_t
d_starts1(size_t n)
{
  if (n == 0) {
    return 1;
  }

  int i = 63 - __clzll(n);

  uint64_t ran = 2;
  while (i > 0) {
    uint64_t temp = 0;
    for (int j = 0; j < 64; j++) {
      if ((ran >> j) & 1) {
        temp ^= c_m2[j];
      }
    }
    ran = temp;
    i -= 1;
    if ((n >> i) & 1) {
      ran = (ran << 1) ^ ((int64_t) ran < 0 ? POLY : 0);
    }
  }

  return ran;
}

enum atomictype_t {
  ATOMICTYPE_CAS,
  ATOMICTYPE_XOR,
};

template<atomictype_t ATOMICTYPE>
__global__ void
d_bench1(size_t n, benchtype *t)
{
  size_t num_threads = gridDim.x * blockDim.x;
  size_t thread_num = blockIdx.x * blockDim.x + threadIdx.x;
  size_t start = thread_num * 4 * n / num_threads;
  size_t end = (thread_num + 1) * 4 * n / num_threads;
  benchtype ran;
  ran.u64 = d_starts1(start);
  for (ptrdiff_t i = start; i < end; ++i) {
    ran.u64 = (ran.u64 << 1) ^ ((int64_t) ran.u64 < 0 ? POLY : 0);
    switch (ATOMICTYPE) {
    case ATOMICTYPE_CAS:
      unsigned long long int *address, old, assumed;
      address = (unsigned long long int *)&t[ran.u64 & (n - 1)].u64;
      old = *address;
      do {
        assumed = old;
        old = atomicCAS(address, assumed, assumed ^ ran.u64);
      } while  (assumed != old);
      break;
    case ATOMICTYPE_XOR:
      atomicXor(&t[ran.u64 & (n - 1)].u32.x, ran.u32.x);
      atomicXor(&t[ran.u64 & (n - 1)].u32.y, ran.u32.y);
      break;
    }
  }
}

static __global__ void
d_check(size_t n, benchtype *t)
{
  for (ptrdiff_t i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    if (t[i].u64 != i) {
      atomicAdd(d_error, 1);
    }
  }
}

static void
starts()
{
  uint64_t m2[64];
  uint64_t temp = 1;
  for (ptrdiff_t i = 0; i < 64; i++) {
    m2[i] = temp;
    temp = (temp << 1) ^ ((int64_t) temp < 0 ? POLY : 0);
    temp = (temp << 1) ^ ((int64_t) temp < 0 ? POLY : 0);
  }
  cudaMemcpyToSymbol(c_m2, m2, sizeof(m2));
}
// end test

int main(int argc, char** argv) {
#ifdef NOCUDA
  init();

  int divisor = 1;

  int ndev;
  cudaGetDeviceCount(&ndev);
  int dev = 0;

  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, dev);
  cudaSetDevice(dev);

  printf("Using GPU %d of %d GPUs.\n", dev, ndev);
  printf("Warp size = %d.\n", prop.warpSize);
  printf("Multi-processor count = %d.\n", prop.multiProcessorCount);
  printf("Max threads per multi-processor = %d.\n", prop.maxThreadsPerMultiProcessor);
  printf("Grid Size = %d.\n", prop.multiProcessorCount * (prop.maxThreadsPerMultiProcessor / prop.warpSize));
  printf("Thread Size = %d.\n", prop.warpSize);

  dim3 grid(prop.multiProcessorCount * (prop.maxThreadsPerMultiProcessor / prop.warpSize));
  dim3 thread(prop.warpSize);

  printf("Size of word container: %lu bytes\n", input_size_h);
  //printf("Number of SMs: %d\n", num_sm);

  printf("Initializing arrays on GPU with %d elements. (%lu bytes)\n", array, rows*input_size_h);
  //unsigned long input_size_TEST = (unsigned long)sizeof(struct uint64_t); // host input size
  //printf("Size of uint64_t = %lu bytes\n", input_size_TEST);
  // << <# blocks per grid, # threads per block> >>
  // max = << <65536,1024> >>
  //d_init << <8192, 2048>> >();
  unsigned blocks_per_grid, threads_per_block;
  blocks_per_grid = 1; //rows/512;
  threads_per_block = 1; // 512;

  printf("Using %d blocks per grid, %d threads per block.\n", blocks_per_grid, threads_per_block);

  // single threaded
  cudaEvent_t read_begin, read_end, write_begin, write_end;
  cudaEventCreate(&read_begin);
  cudaEventCreate(&read_end);
  cudaEventCreate(&write_begin);
  cudaEventCreate(&write_end);

  float ms, ms_read_random, ms_write_random;

  /*
  // random gather //
  printf("Benching overall.\n");
  cudaEventRecord(read_begin);
  d_bench <<<blocks_per_grid, threads_per_block>>>();
  cudaEventRecord(read_end);
  cudaEventSynchronize(read_end);

  // print gather rate
  cudaEventElapsedTime(&ms, read_begin, read_end);
  ms = ms/divisor;
  printf("%lu-byte gather average = %.6f us; ", input_size_h, (ms*1000)/rows);
  printf("rate = %.3f MB/s.\n", convert_to_MBs(ms));
  */

  // random read/write //
  printf("Benching random reads.\n");
  cudaEventRecord(read_begin);
  cudaEventSynchronize(read_begin);
  d_bench_read_random <<<blocks_per_grid, threads_per_block>>>();
  cudaEventRecord(read_end);
  cudaEventSynchronize(read_end);

  // print random read rate
  cudaEventElapsedTime(&ms_read_random, read_begin, read_end);
  ms_read_random = (ms_read_random)/divisor;
  printf("%lu-byte random read average = %.6f us; ", input_size_h, (ms_read_random*1000)/rows);
  printf("rate = %.3f MB/s.\n", convert_to_MBs(ms_read_random));

  // random read/write //
  printf("Benching random writes.\n");
  cudaEventRecord(write_begin);
  cudaEventSynchronize(write_begin);
  d_bench_write_random <<<blocks_per_grid, threads_per_block>>>();
  cudaEventRecord(write_end);
  cudaEventSynchronize(write_end);
  
  // print random read rate
  cudaEventElapsedTime(&ms_write_random, write_begin, write_end);
  ms_write_random = (ms_write_random)/divisor;
  printf("%lu-byte random write average = %.6f us; ", input_size_h, (ms_write_random*1000)/rows);
  printf("rate = %.3f MB/s.\n", convert_to_MBs(ms_write_random));
  //printf("rate = %.3f MT/s.\n", convert_to_Ts(ms_write_random));

  checkCudaErrors(cudaMemcpyFromSymbol(A, d_A, sizeof(d_A)));
  checkCudaErrors(cudaMemcpyFromSymbol(in, d_in, sizeof(d_in)));
  checkCudaErrors(cudaMemcpyFromSymbol(out, d_out, sizeof(d_out)));

  cudaEventDestroy(write_end);
  cudaEventDestroy(write_begin);
  cudaEventDestroy(read_end);
  cudaEventDestroy(read_begin);
  //printf("Elapsed time = %.6f seconds.\n", (ms_read_linear + ms_write_linear + ms_read_random + ms_write_random)/1000);

  //double time = ms * 1.0e-3;
  //printf("GPU elapsed time = %.6f seconds.\n", time);

  // test start //
  size_t n = 0;
  if (argc > 1) {
    int logn = atoi(argv[1]);
    if (logn >= 0) {
      n = (size_t) 1 << logn;
    }
  }
  if (n <= 0) {
    n = (size_t) 1 << DEFAULT_LOGN;
  }
  printf("Total table size = %lu (%lu bytes.)\n",
         n, n * sizeof(uint64_t));

  starts();

  //int ndev;
  //cudaGetDeviceCount(&ndev);
  //int dev = 0;
  if (argc > 2) {
    dev = atoi(argv[2]);
  }
  if (dev < 0 || dev >= ndev) {
    dev = 0;
  }
  /*
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, dev);
  cudaSetDevice(dev);
  printf("Using GPU %d of %d GPUs.\n", dev, ndev);
  printf("Warp size = %d.\n", prop.warpSize);
  printf("Multi-processor count = %d.\n", prop.multiProcessorCount);
  printf("Max threads per multi-processor = %d.\n",
         prop.maxThreadsPerMultiProcessor);
  */

  benchtype *d_t;
  if (cudaMalloc((void **)&d_t, n * sizeof(benchtype)) != cudaSuccess) {
    fprintf(stderr, "Memory allocation failed!\n");
    exit(-1);
  }

  //dim3 grid(prop.multiProcessorCount *
  //          (prop.maxThreadsPerMultiProcessor / prop.warpSize));
  //dim3 thread(prop.warpSize);
  cudaEvent_t begin, end;
  cudaEventCreate(&begin);
  cudaEventCreate(&end);
  d_init1<<<grid, thread>>>(n, d_t);
  cudaEventRecord(begin);
  cudaEventSynchronize(begin);
  d_bench1<ATOMICTYPE_CAS><<<grid, thread>>>(n, d_t);
  cudaEventRecord(end);
  cudaEventSynchronize(end);

  //float ms;
  cudaEventElapsedTime(&ms, begin, end);
  cudaEventDestroy(end);
  cudaEventDestroy(begin);
  double time = ms * 1.0e-3;
  printf("Elapsed time = %.6f seconds.\n", time);
  double gups = 4 * n / (double) ms * 1.0e-6;
  printf("Giga Updates per second = %.6f GUP/s.\n", gups);
  d_bench1<ATOMICTYPE_CAS><<<grid, thread>>>(n, d_t);
  void *p_error;
  cudaGetSymbolAddress(&p_error, d_error);
  cudaMemset(d_error, 0, sizeof(uint32_t));
  d_check<<<grid, thread>>>(n, d_t);
  uint32_t h_error;
  cudaMemcpy(&h_error, p_error, sizeof(uint32_t), cudaMemcpyDeviceToHost);
  printf("Verification: Found %u errors.\n", h_error);

  cudaFree(d_t);
//return 0;
  

#endif // !1

#ifdef VERIF
  //d_check << <grid, thread >> >(n, d_t);
  //cpu_bench();
#endif // VERIF
  /**
  printf("Copying host arrays from device.\n");
  checkCudaErrors(cudaMemcpyFromSymbol(A, d_A, sizeof(d_A)));
  //checkCudaErrors(cudaMemcpyFromSymbol(h_B, d_B, sizeof(d_B)));
  checkCudaErrors(cudaMemcpyFromSymbol(in, d_in, sizeof(d_in)));
  //checkCudaErrors(cudaMemcpyFromSymbol(out, d_out, sizeof(d_out)));
  //checkCudaErrors(cudaMemcpyFromSymbol(h_out2, d_out2, sizeof(d_out2)));
  //checkCudaErrors(cudaMemcpyFromSymbol(h_agg1, d_agg1, sizeof(d_agg1)));
  //checkCudaErrors(cudaMemcpyFromSymbol(h_agg2, d_agg2, sizeof(d_agg2)));
  printf("Successfully copied GPU arrays.\n");**/

#ifdef NOCUDA

  cudaFree(d_A);
  cudaFree(d_in);
  cudaFree(d_out);
  //cudaFree(d_out2);
  //cudaFree(d_agg1);
  //cudaFree(d_agg2);

  cudaFree(dd_A);
  cudaFree(dd_B);
  cudaFree(dd_in);
  cudaFree(dd_out);
  cudaFree(dd_out2);

#endif // !1
  //unsigned i;
/**
#ifdef CPU_BENCH
  printf("Beginning CPU benchmark.\n");
  struct timeval t0, t1;
  gettimeofday(&t0, 0);
  // Gather rows
  for (i = 0; i < rows; i++) {
          h_out[i] = h_A[h_in[i]];
  }
  // Indirect Gather rows
  for (i = 0; i < rows; i++) {
          h_out[i] = h_A[h_A[h_in[i]].measure];
  }

  // Fused gather group
  for (i = 0; i < rows; i++) {
          h_agg2[h_A[h_in[i]].group] += h_A[h_in[i]].measure;
#ifdef DEBUG
          printf("CPU:  h_agg2[h_A[h_in[i]].group]  = %d\n", h_agg2[h_A[h_in[i]].group]);
#endif // DEBUG
  }
  gettimeofday(&t1, 0);
  printf("CPU bench successful.\n");
  long elapsed = ((t1.tv_sec-t0.tv_sec)*1000000 + t1.tv_usec-t0.tv_usec);
  printf("CPU elapsed time = %lu microseconds.\n", elapsed);

#endif // CPU_BENCH
**/
  return 0;
}
