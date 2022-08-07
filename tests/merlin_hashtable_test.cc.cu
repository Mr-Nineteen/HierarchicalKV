/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <algorithm>
#include <iostream>
#include <random>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include "merlin/initializers.cuh"
#include "merlin/optimizers.cuh"
#include "merlin_hashtable.cuh"

uint64_t getTimestamp() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

template <class K, class M>
void create_random_keys(K* h_keys, M* h_metas, int KEY_NUM) {
  std::unordered_set<K> numbers;
  std::random_device rd;
  std::mt19937_64 eng(rd());
  std::uniform_int_distribution<K> distr;
  int i = 0;

  while (numbers.size() < KEY_NUM) {
    numbers.insert(distr(eng));
  }
  for (const K num : numbers) {
    h_keys[i] = num;
    h_metas[i] = getTimestamp();
    i++;
  }
}

template <class K, class M>
void create_continuous_keys(K* h_keys, M* h_metas, int KEY_NUM, K start = 0) {
  for (K i = 0; i < KEY_NUM; i++) {
    h_keys[i] = start + static_cast<K>(i);
    h_metas[i] = getTimestamp();
  }
}

template <class V, size_t DIM>
struct ValueArray {
  V value[DIM];
};

constexpr uint64_t INIT_CAPACITY = 64 * 1024 * 1024UL;
constexpr uint64_t MAX_CAPACITY = INIT_CAPACITY;
constexpr uint64_t KEY_NUM = 1 * 1024 * 1024UL;
constexpr uint64_t TEST_TIMES = 1;
constexpr uint64_t DIM = 2;

template <class K, class M>
__forceinline__ __device__ bool erase_if_pred(const K& key, const M& meta) {
  return ((key % 2) == 1);
}

using K = uint64_t;
using M = uint64_t;
using Vector = ValueArray<float, DIM>;
using Table = nv::merlin::HashTable<K, float, M, DIM>;
using TableOptions = nv::merlin::HashTableOptions;

/* A demo of Pred for erase_if */
template <class K, class M>
__device__ Table::Pred pred = erase_if_pred<K, M>;

int test_main() {
  K* h_keys;
  M* h_metas;
  Vector* h_vectors;
  bool* h_found;

  TableOptions options;

  options.init_capacity = INIT_CAPACITY;
  options.max_capacity = MAX_CAPACITY;
  options.max_hbm_for_vectors = nv::merlin::GB(16);

  std::unique_ptr<Table> table = std::make_unique<Table>();
  table->init(options);

  CUDA_CHECK(cudaMallocHost(&h_keys, KEY_NUM * sizeof(K)));
  CUDA_CHECK(cudaMallocHost(&h_metas, KEY_NUM * sizeof(M)));
  CUDA_CHECK(cudaMallocHost(&h_vectors, KEY_NUM * sizeof(Vector)));
  CUDA_CHECK(cudaMallocHost(&h_found, KEY_NUM * sizeof(bool)));

  CUDA_CHECK(cudaMemset(h_vectors, 0, KEY_NUM * sizeof(Vector)));

  create_random_keys<K, M>(h_keys, h_metas, KEY_NUM);

  K* d_keys;
  M* d_metas = nullptr;
  Vector* d_vectors;
  Vector* d_def_val;
  Vector** d_vectors_ptr;
  bool* d_found;
  size_t dump_counter = 0;

  CUDA_CHECK(cudaMalloc(&d_keys, KEY_NUM * sizeof(K)));
  CUDA_CHECK(cudaMalloc(&d_metas, KEY_NUM * sizeof(M)));
  CUDA_CHECK(cudaMalloc(&d_vectors, KEY_NUM * sizeof(Vector)));
  CUDA_CHECK(cudaMalloc(&d_def_val, KEY_NUM * sizeof(Vector)));
  CUDA_CHECK(cudaMalloc(&d_vectors_ptr, KEY_NUM * sizeof(Vector*)));
  CUDA_CHECK(cudaMalloc(&d_found, KEY_NUM * sizeof(bool)));

  CUDA_CHECK(
      cudaMemcpy(d_keys, h_keys, KEY_NUM * sizeof(K), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_metas, h_metas, KEY_NUM * sizeof(M),
                        cudaMemcpyHostToDevice));

  CUDA_CHECK(cudaMemset(d_vectors, 1, KEY_NUM * sizeof(Vector)));
  CUDA_CHECK(cudaMemset(d_def_val, 2, KEY_NUM * sizeof(Vector)));
  CUDA_CHECK(cudaMemset(d_vectors_ptr, 0, KEY_NUM * sizeof(Vector*)));
  CUDA_CHECK(cudaMemset(d_found, 0, KEY_NUM * sizeof(bool)));

  cudaStream_t stream;
  CUDA_CHECK(cudaStreamCreate(&stream));

  uint64_t total_size = 0;
  for (int i = 0; i < TEST_TIMES; i++) {
    total_size = table->size(stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    assert(total_size == 0);

    std::cout << "before insert_or_assign: total_size = " << total_size
              << std::endl;
    table->insert_or_assign(
        KEY_NUM, d_keys, reinterpret_cast<float*>(d_vectors), d_metas, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));

    total_size = table->size(stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    std::cout << "after 1st insert_or_assign: total_size = " << total_size
              << std::endl;
    assert(total_size == KEY_NUM);

    CUDA_CHECK(cudaMemset(d_vectors, 2, KEY_NUM * sizeof(Vector)));
    table->insert_or_assign(
        KEY_NUM, d_keys, reinterpret_cast<float*>(d_vectors), d_metas, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));

    total_size = table->size(stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    std::cout << "after 2nd insert_or_assign: total_size = " << total_size
              << std::endl;
    assert(total_size == KEY_NUM);

    table->find(KEY_NUM, d_keys, reinterpret_cast<float*>(d_vectors), d_found,
                nullptr, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    int found_num = 0;
    CUDA_CHECK(cudaMemcpy(h_found, d_found, KEY_NUM * sizeof(bool),
                          cudaMemcpyDeviceToHost));

    for (int i = 0; i < KEY_NUM; i++) {
      if (h_found[i]) found_num++;
    }
    std::cout << "after find, found_num = " << found_num << std::endl;
    assert(found_num == KEY_NUM);

    table->accum_or_assign(KEY_NUM, d_keys, reinterpret_cast<float*>(d_vectors),
                           d_found, d_metas, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));

    total_size = table->size(stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    std::cout << "after accum: total_size = " << total_size << std::endl;
    assert(total_size == KEY_NUM);

    size_t erase_num = table->erase_if(pred<K, M>, stream);
    total_size = table->size(stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    std::cout << "after erase_if: total_size = " << total_size
              << ", erase_num = " << erase_num << std::endl;
    assert((erase_num + total_size) == KEY_NUM);

    table->clear(stream);
    total_size = table->size(stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    std::cout << "after clear: total_size = " << total_size << std::endl;
    assert(total_size == 0);

    table->insert_or_assign(
        KEY_NUM, d_keys, reinterpret_cast<float*>(d_vectors), d_metas, stream);

    dump_counter = table->export_batch(table->capacity(), 0, d_keys,
                                       reinterpret_cast<float*>(d_vectors),
                                       d_metas, stream);
    CUDA_CHECK(cudaStreamSynchronize(stream));
    std::cout << "after export_batch: dump_counter = " << dump_counter
              << std::endl;
    assert(dump_counter == KEY_NUM);
  }
  CUDA_CHECK(cudaStreamDestroy(stream));

  CUDA_CHECK(cudaMemcpy(h_vectors, d_vectors, KEY_NUM * sizeof(Vector),
                        cudaMemcpyDeviceToHost));

  CUDA_CHECK(cudaFreeHost(h_keys));
  CUDA_CHECK(cudaFreeHost(h_metas));
  CUDA_CHECK(cudaFreeHost(h_found));

  CUDA_CHECK(cudaFree(d_keys));
  CUDA_CHECK(cudaFree(d_metas))
  CUDA_CHECK(cudaFree(d_vectors));
  CUDA_CHECK(cudaFree(d_def_val));
  CUDA_CHECK(cudaFree(d_vectors_ptr));
  CUDA_CHECK(cudaFree(d_found));

  CudaCheckError();
  std::cout << "All test cases passed!" << std::endl;

  return 0;
}

int main() {
  test_main();
  return 0;
}
