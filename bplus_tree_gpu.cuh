#pragma once
#include "gpu_helper.cuh"
#include "preparing_tree.cuh"
#include "helpers.h"

struct output_create_leafs
{
	int usedNodes;
	int isOnlyRoot;
	int rootNodeIndex;
};

struct output_create_next_layer
{
	int lastUsedIndex;
	int isRoot;
};

template<class HASH, int B>
__global__ void kernel_create_next_layer(const int threadsNum, const int beginIndex, const int endIndex, int* indexArray, HASH* keysArray, int* sizeArray, HASH *minArray)
{
	only_gpu_assert();
	const int globalId = GetGlobalId();
	const int minIndexesPerNode = B / 2 + 1;
	const int maxIndexesPerNode = B + 1;
	const int minKeysPerNode = B / 2;
	const int maxKeysPerNode = B;
	const int createdNodes = endIndex - beginIndex; //How many nodes were last time created
	//Creation of new layer
	int toCreate = my_max(1, createdNodes / (B / 2 + 1)); //How many nodes will be created in this iteration
	if (toCreate <= 0)
		toCreate = 1;
	//In each node there will be at least B / 2 keys and B / 2 + 1 indexes to lower layer nodes
	int id = globalId;
	while (id < createdNodes)
	{
		int _nodeNumber = id / minIndexesPerNode;
		const bool addToPrevious = _nodeNumber == toCreate;
		_nodeNumber += addToPrevious ? -1 : 0;
		const int& nodeNumber = _nodeNumber;
		const int nodeIndex = endIndex + nodeNumber;
		const int indexInNode = id - nodeNumber * minIndexesPerNode;
		const int lowerNode = beginIndex + id;
		indexArray[nodeIndex * maxIndexesPerNode + indexInNode] = lowerNode;
		if (indexInNode != 0)
		{
			keysArray[nodeIndex * maxKeysPerNode + indexInNode - 1] = minArray[lowerNode];
		}
		id += threadsNum;
	}
	//Filling size of nodes
	id = globalId;
	while (id < toCreate)
	{
		const int &nodeNumber = id;
		const int nodeIndex = endIndex + nodeNumber;
		const bool isLast = nodeNumber == toCreate - 1;
		const int firstLowerNode = beginIndex + id * minIndexesPerNode;
		sizeArray[nodeIndex] = isLast ? createdNodes - (toCreate - 1) * minIndexesPerNode - 1 : minKeysPerNode;
		minArray[nodeIndex] = minArray[firstLowerNode];
		id += threadsNum;
	}
}

template<class HASH, int B>
__global__ void kernel_create_leafs(const int threadsNum, const int elementNum, HASH* hashesArray, int* valueArray, HASH* keysArray, int* sizeArray, int* indexesArray, HASH* minArray)
{
	only_gpu_assert();
	const int globalId = GetGlobalId();
	const int maxIndexesPerNode = B + 1;
	const int minKeysPerNode = B / 2;
	const int maxKeysPerNode = B;
	int bottomPages = my_max(1, elementNum * 2 / B); //How many pages will be created
	const int elementsOnLastPage = elementNum - (bottomPages - 1) * B / 2;
	if (elementsOnLastPage < B / 2 && bottomPages > 1) //If elements on last page are less then half size of page
		bottomPages -= 1;
	int id = globalId;
	while (id < elementNum)
	{
		int _nodeIndex = id / minKeysPerNode;
		const bool addToPrevious = _nodeIndex == bottomPages;
		_nodeIndex += addToPrevious ? -1 : 0;
		const int& nodeIndex = _nodeIndex;
		const int indexInNode = id - nodeIndex * minKeysPerNode;
		keysArray[nodeIndex * maxKeysPerNode + indexInNode] = hashesArray[id];
		indexesArray[nodeIndex * maxIndexesPerNode + indexInNode] = valueArray[id];
		id += threadsNum;
	}
	id = globalId;
	while (id < bottomPages)
	{
		const int &nodeIndex = id;
		const bool isLast = nodeIndex == bottomPages - 1;
		sizeArray[nodeIndex] = isLast ? elementNum - (bottomPages - 1) * minKeysPerNode : minKeysPerNode;
		minArray[nodeIndex] = hashesArray[nodeIndex * minKeysPerNode];
		indexesArray[nodeIndex * maxIndexesPerNode + maxIndexesPerNode - 1] = isLast ? -1 : nodeIndex + 1;
		id += threadsNum;
	}
}

template<class HASH, int B, class Output>
__global__ void kernel_get_value(const int threadsNum, const int elementNum, const HASH* keysArray,
	const int* sizeArray, const int* indexesArray, const HASH* toFind, const int height, const int rootIndex, Output* output)
{
	only_gpu_assert();
	const int globalId = GetGlobalId();
	const int maxIndexesPerNode = B + 1;
	const int maxKeysPerNode = B;
	int id = globalId;
	while (id < elementNum)
	{
		const HASH key = toFind[id];
		int currentHeight = 0;
		int node = rootIndex;
		//Inner nodes
		while (currentHeight < height)
		{
			const int size = sizeArray[node];
			const HASH *keys_begin = keysArray + node * maxKeysPerNode;
			const HASH *keys_end = keys_begin + size;
			const HASH *keys = keys_begin;
			while (keys < keys_end && *keys <= key)
			{
				++keys;
			}
			node = indexesArray[node * maxIndexesPerNode + (keys - keys_begin)];
			currentHeight += 1;
		}
		//Leaf level
		{
			const int size = sizeArray[node];
			const HASH *keys_begin = keysArray + node * maxKeysPerNode;
			const HASH *keys_end = keys_begin + size;
			const HASH *keys = keys_begin;
			while (keys < keys_end && *keys < key)
			{
				++keys;
			}
			if (keys < keys_end && *keys == key)
			{
				if (std::is_same<Output, bool>::value)
					output[id] = true;
				else
					output[id] = indexesArray[node * maxIndexesPerNode + (keys - keys_begin)];
			}
			else
			{
				if (std::is_same<Output, bool>::value)
					output[id] = false;
				else
					output[id] = static_cast<Output>(-1);
			}
		}
		id += threadsNum;
	}
}

#pragma region search_kernels

template <class HASH, int B>
__global__ void kernel_find_words_v1(const int threadsNum, const HASH* keysArray, const int* indexesArray, const int* sizeArray,
	const int rootIndex, const int height, const char* suffixes, const int suffixesSize, const int elementsNum, const char* words,
	const int* beginIndexes, bool* output)
{
	const int globalId = GetGlobalId();
	const int maxIndexesPerNode = B + 1;
	const int maxKeysPerNode = B;
	int id = globalId;
	while (id < elementsNum)
	{
		const int beginIdx = beginIndexes[id];
		const HASH key = get_hash<HASH>(words, beginIdx);
		int currentHeight = 0;
		int node = rootIndex;
		//Inner nodes
		while (currentHeight < height)
		{
			const int size = sizeArray[node];
			const HASH *keys_begin = keysArray + node * maxKeysPerNode;
			const HASH *keys_end = keys_begin + size;
			const HASH *keys = keys_begin;
			while (keys < keys_end && *keys <= key)
			{
				++keys;
			}
			node = indexesArray[node * maxIndexesPerNode + (keys - keys_begin)];
			currentHeight += 1;
		}
		int suffixIdx, endSuffixIdx = -1;
		//Leaf level
		{
			const int size = sizeArray[node];
			const HASH *keys_begin = keysArray + node * maxKeysPerNode;
			const HASH *keys_end = keys_begin + size;
			const HASH *keys = keys_begin;
			while (keys < keys_end && *keys < key)
			{
				++keys;
			}
			if (keys < keys_end && *keys == key)
			{
				const int indexInKeyArray = keys - keys_begin;
				suffixIdx = indexesArray[node * maxIndexesPerNode + indexInKeyArray];
				if (indexInKeyArray < size - 1) //Next element is in the same leaf
				{
					endSuffixIdx = indexesArray[node * maxIndexesPerNode + indexInKeyArray + 1];
				}
				else //Next element is in the next leaf
				{
					if (indexesArray[node * maxIndexesPerNode + maxIndexesPerNode - 1] != -1) //Next leaf exists
					{
						endSuffixIdx = indexesArray[(node + 1) * maxIndexesPerNode];
					}
					else //It is the last element in the last leaf
					{
						endSuffixIdx = suffixesSize;
					}
				}
			}
			else
			{
				suffixIdx = -1;
			}
		}
		bool result = false;
		if (suffixIdx < 0)
		{
			result = false;
		}
		else if (key & 0x1) //There is suffix to check
		{
			const char nullByte = static_cast<char>(0);
			const char *endSuffixIt = suffixes + endSuffixIdx;
			for (const char *suffixIt = suffixes + suffixIdx; suffixIt < endSuffixIt; ++suffixIt)
			{
				const char *wordIt = words + beginIdx + CHARSTOHASH; //Pointer to suffix of the word
				while (*suffixIt != nullByte && *wordIt != nullByte)
				{
					if (*suffixIt != *wordIt)
						break;
					++suffixIt;
					++wordIt;
				}
				if (*suffixIt == nullByte && *wordIt == nullByte)
				{
					result = true;
					break;
				}
				while (*suffixIt != nullByte)
				{
					++suffixIt;
				}
			}
		}
		else
		{
			result = true;
		}
		output[id] = result;
		id += threadsNum;
	}
}

template <class HASH, int B>
__device__ __inline__ void get_leaf_node(const HASH* keysArray, const int* indexesArray, const int* sizeArray, const int height, const HASH key, int& node)
{
	const int max_indexes_per_node = B + 1;
	const int max_keys_per_node = B;

	for (int currentHeight = 0; currentHeight < height; currentHeight++)
	{
		const int size = sizeArray[node];
		int start_index = node * max_keys_per_node;
		int end_index = start_index + size;

		while (start_index + 1 != end_index)
		{
			const int mid = end_index + start_index >> 1;
			if (keysArray[mid] <= key)
				start_index = mid;
			else
				end_index = mid;
		}

		if (keysArray[start_index] <= key)
			++start_index;

		node = indexesArray[start_index + node * (max_indexes_per_node - max_keys_per_node)];
	}
}

template <class HASH, int B>
__device__ __inline__ void find_suffix_indices(const HASH* keysArray, const int* indexesArray, const int* sizeArray,
	const int suffixesSize, const HASH key, int node, int& suffix_idx, int& end_suffix_idx)
{
	const int max_indexes_per_node = B + 1;
	const int max_keys_per_node = B;

	const int size = sizeArray[node];
	int start_index = node * max_keys_per_node;
	int end_index = start_index + size;

	int index;

	while (start_index + 1 != end_index)
	{
		index = end_index + start_index >> 1;
		if (keysArray[index] <= key)
			start_index = index;
		else
			end_index = index;
	}

	index = start_index;
	start_index = node * max_keys_per_node;
	end_index = start_index + size;

	if (index >= end_index || keysArray[index] != key)
		return;

	const int index_in_key_array = index - start_index;
	suffix_idx = indexesArray[node * max_indexes_per_node + index_in_key_array];

	if (index_in_key_array < size - 1)
		//Next element is in the same leaf
		end_suffix_idx = indexesArray[node * max_indexes_per_node + index_in_key_array + 1];
	else
		//Next element is in the next leaf
		if (indexesArray[node * max_indexes_per_node + max_indexes_per_node - 1] != -1)
			//Next leaf exists
			end_suffix_idx = indexesArray[(node + 1) * max_indexes_per_node];
		else
			//It is the last element in the last leaf
			end_suffix_idx = suffixesSize;
}

template <class HASH>
__device__ __inline__ bool check_suffix(const char* suffixes, const char* words, const int begin_idx, int& suffix_idx, const int end_suffix_idx)
{
	const auto null_byte = static_cast<char>(0);
	for (; suffix_idx < end_suffix_idx; ++suffix_idx)
	{
		int word_suffix_index = begin_idx + chars_in_type<HASH>;;
		while (true)
		{
			const auto dict_char = suffixes[suffix_idx];
			const auto word_char = words[word_suffix_index];
			if (dict_char == null_byte && word_char == null_byte)
				return true;

			if (dict_char != word_char || dict_char == null_byte || word_char == null_byte)
				break;

			++word_suffix_index;
			++suffix_idx;
		}

		while (suffixes[suffix_idx] != null_byte)
			++suffix_idx;
	}
	return false;
}

template <class HASH, int B>
__global__ void kernel_find_words_v2(const HASH* keysArray, const int* indexesArray, const int* sizeArray,
	const int rootIndex, const int height, const char* suffixes, const int suffixesSize, const int elementsNum, const char* words,
	const int* beginIndexes, bool* output)
{
	const int id = GetGlobalId();
	if (id >= elementsNum)
		return;

	const int beginIdx = beginIndexes[id];
	const HASH key = get_hash<HASH>(words, beginIdx);
	int node = rootIndex;

	get_leaf_node<HASH, B>(keysArray, indexesArray, sizeArray, height, key, node);

	int suffix_idx;
	int end_suffix_idx = -1;
	find_suffix_indices<HASH, B>(keysArray, indexesArray, sizeArray, suffixesSize, key, node, suffix_idx, end_suffix_idx);

	if (end_suffix_idx == -1)
		return;//false

	if (!(key & 0x1))
	{
		output[id] = true;
		return;
	}

	output[id] = check_suffix<HASH>(suffixes, words, beginIdx, suffix_idx, end_suffix_idx);
}

#pragma endregion

template <class HASH, int B>
class bplus_tree_gpu
{
public:
	thrust::device_vector<char> suffixes;
	thrust::device_vector<int> indexes;
	thrust::device_vector<HASH> keys;
	thrust::device_vector<int> sizes;
	thrust::device_vector<HASH> mins;
	int usedNodes;
	int rootNodeIndex;
	int height;
	void create_tree(const thrust::device_vector<char>& words, thrust::device_vector<int>& sorted_positions);

	void exist(const thrust::device_vector<HASH>& keys, int size, thrust::device_vector<bool>& output) const;

	template<int Version>
	void exist_word(const thrust::device_vector<char>& words, const thrust::device_vector<int>& indexes, thrust::device_vector<bool>& output) const;

	void get_value(const thrust::device_vector<HASH>& keys, int size, thrust::device_vector<bool>& output) const;

	int get_height() const;
};

template <class HASH, int B>
void bplus_tree_gpu<HASH, B>::create_tree(const thrust::device_vector<char>& words, thrust::device_vector<int>& sorted_positions)
{
	thrust::device_vector<HASH> hashes;
	thrust::device_vector<int> values;

	create_output(words, sorted_positions, hashes, values, suffixes);

	const auto size = static_cast<int>(hashes.size());
	height = 0;
	const auto node_count = needed_nodes<B>(size);
	indexes.resize(node_count*(B + 1));
	keys.resize(node_count*B);
	sizes.resize(node_count);
	mins.resize(node_count);

	int blocks_num = size <= 32 ? 1 : 2;
	int threads_num = size <= 32 ? 32 : std::min(size / 2, 1024);

	kernel_create_leafs<HASH, B> kernel_init(blocks_num, threads_num) (threads_num, size, hashes.data().get(),
		values.data().get(), keys.data().get(), sizes.data().get(), indexes.data().get(), mins.data().get());

	gpuErrchk(cudaGetLastError());

	int last_created = std::max(1, size * 2 / B);
	int begin_index = 0;
	int end_index = last_created;
	while (last_created != 1)
	{
		height += 1;

		blocks_num = last_created <= 32 ? 1 : 2;
		threads_num = last_created <= 32 ? 32 : std::min(last_created / 2, 1024);

		kernel_create_next_layer<HASH, B> kernel_init(blocks_num, threads_num) (threads_num, begin_index, end_index,
			indexes.data().get(), keys.data().get(), sizes.data().get(), mins.data().get());

		gpuErrchk(cudaGetLastError());

		last_created = std::max(1, last_created / (B / 2 + 1));
		begin_index = end_index;
		end_index = end_index + last_created;
	}

	rootNodeIndex = end_index - 1;
	usedNodes = end_index;
}

template <class HASH, int B>
void bplus_tree_gpu<HASH, B>::exist(const thrust::device_vector<HASH>& keys, const int size, thrust::device_vector<bool>& output) const
{
	const int elementNum = size;
	output.resize(size);

	const int blocksNum = elementNum <= 32 ? 1 : 2;
	const int threadsNum = elementNum <= 32 ? 32 : std::min(elementNum / 2, 1024);

	kernel_get_value<HASH, B> kernel_init(blocksNum, threadsNum) (threadsNum, elementNum, this->keys.data().get(),
		sizes.data().get(), indexes.data().get(), keys.data().get(), height, rootNodeIndex, output.data().get());

	gpuErrchk(cudaGetLastError());
}

inline void compute_grid_size(uint n, uint block_size, uint &num_blocks, uint &num_threads)
{
	num_threads = block_size < n ? block_size : n;
	num_blocks = (n % num_threads != 0) ? (n / num_threads + 1) : (n / num_threads);
}

template <class HASH, int B>
template <int Version>
void bplus_tree_gpu<HASH, B>::exist_word(const thrust::device_vector<char>& words, const thrust::device_vector<int>& word_indexes, thrust::device_vector<bool>& output) const
{
	constexpr int MAX_VERSION = 2;
	static_assert(Version >= 1 || Version <= MAX_VERSION, "Selected version does not exist.");

	const int elementNum = static_cast<int>(word_indexes.size());
	output.resize(elementNum);

	uint blocksNum;
	uint threadsNum;
	compute_grid_size(elementNum, BLOCKSIZE, blocksNum, threadsNum);

	if (Version == 1)
	{
		kernel_find_words_v1<HASH, B> kernel_init(blocksNum, threadsNum)(threadsNum, keys.data().get(), indexes.data().get(),
			sizes.data().get(), rootNodeIndex, height, suffixes.data().get(), static_cast<int>(suffixes.size()),
			elementNum, words.data().get(), word_indexes.data().get(), output.data().get());
	}
	else if (Version == 2)
	{
		kernel_find_words_v2<HASH, B> kernel_init(blocksNum, threadsNum)(keys.data().get(), indexes.data().get(),
			sizes.data().get(), rootNodeIndex, height, suffixes.data().get(), static_cast<int>(suffixes.size()),
			elementNum, words.data().get(), word_indexes.data().get(), output.data().get());
	}

	gpuErrchk(cudaGetLastError());
}

template <class HASH, int B>
void bplus_tree_gpu<HASH, B>::get_value(const thrust::device_vector<HASH>& keys, const int size, thrust::device_vector<bool>& output) const
{
	const int elementNum = size;
	output.resize(size);

	const int blocksNum = elementNum <= 32 ? 1 : 2;
	const int threadsNum = elementNum <= 32 ? 32 : std::min(elementNum / 2, 1024);
	kernel_get_value<HASH, B> kernel_init(blocksNum, threadsNum) (threadsNum, elementNum, this->keys.data().get(),
		sizes.data().get(), indexes.data().get(), keys.data().get(), height, rootNodeIndex, output.data().get());

	gpuErrchk(cudaGetLastError());
}

template <class HASH, int B>
int bplus_tree_gpu<HASH, B>::get_height() const
{
	return height;
}
