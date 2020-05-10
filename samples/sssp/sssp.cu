
#include "common.cuh"
#include "frontier.cuh"
#include "graph.cuh"
#include "graph_loader.cuh"
#include "kernel.cuh"
#include "worklist.cuh"
#include <gflags/gflags.h>
using namespace mgg;

DECLARE_int32(device);
DECLARE_string(input);
DECLARE_int32(src);

namespace sssp {

__global__ void SSSPInit(uint *label, int nnodes, vtx_t source) {
  int tid = TID_1D;
  if (tid < nnodes) {
    label[tid] = tid == source ? 0 : INFINIT;
  }
}
class job_t {
public:
  uint src;
  uint *label;
  uint itr = 0;
  vtx_t num_Node;
  weight_t *adjwgt = nullptr;
  void operator()(vtx_t _num_Node, uint _src, weight_t *_adjwgt) {
    num_Node = _num_Node;
    src = _src;
    adjwgt = _adjwgt;
    init();
  }
  void init() {
    H_ERR(cudaMalloc(&label, num_Node * sizeof(uint)));
    SSSPInit<<<num_Node / BLOCK_SIZE + 1, BLOCK_SIZE>>>(label, num_Node, src);
  }
};

struct updater {
  __forceinline__ __device__ bool operator()(vtx_t src, vtx_t dst,
                                             vtx_t edge_id, job_t job) {
    if (job.label[dst] > job.label[src] + job.adjwgt[edge_id]) {
      job.label[dst] = job.label[src] + job.adjwgt[edge_id];
      return true;
    }
    return false;
  }
};
struct generator {
  __forceinline__ __device__ void operator()(bool updated,
                                             worklist::Worklist wl, vtx_t dst) {
    if (updated)
      wl.append(dst);
  }
  __forceinline__ __device__ void operator()(bool updated, char *flag,
                                             vtx_t dst) {
    if (updated)
      flag[dst] = true;
  }
  __forceinline__ __device__ void operator()(bool updated, char *flag,
                                             vtx_t dst, char *finished) {
    if (updated) {
      flag[dst] = true;
      *finished = false;
    }
  }
};

} // namespace sssp

bool SSSPSingle() {
  cudaSetDevice(FLAGS_device);
  H_ERR(cudaDeviceReset());
  graph_t<CSR> G(true);
  graph_loader loader;
  loader.Load(G, true);
  // LOG("make g1 chunks\n");
  // G.make_chunks(4);
  // for (size_t i = 0; i < 4; i++) {
  //   cout << "G " << i << G.chunks[i] << endl;
  // }
  // graph_t<CSC> G2;
  // G2.CSR2CSC(G);
  // G2.make_chunks(4);
  // for (size_t i = 0; i < 4; i++) {
  //   cout << "G2 " << i << G2.chunks[i] << endl;
  // }

  LOG("SSSP single\n");
  cudaStream_t stream;
  cudaStreamCreate(&stream);
  // G.Init(false);
  sssp::job_t job;
  job(G.numNode, FLAGS_src, G.adjwgt);
  frontier::Frontier<BDF_AUTO> F; // BDF  BDF_AUTO BITMAP
  F.Init(G.numNode, FLAGS_src, FLAGS_device, 1.0, false);
  G.Set_Mem_Policy(&stream); // stream
  cudaDeviceSynchronize();
  Timer t;
  t.Start();
  kernel<graph_t<CSR>, frontier::Frontier<BDF_AUTO>, sssp::updater,
         sssp::generator, sssp::job_t>
      K;
  while (!F.finish()) {
    // cout << "itr " << job.itr << " wl_sz " << F.wl_sz << endl;
    K(G, F, job);
    cudaDeviceSynchronize();
    // H_ERR(cudaStreamSynchronize(stream));
    F.Next();
    job.itr++;
  }
  cout << "itr " << job.itr << " in " << t.Finish() << endl;
  return 0;
}
