#include "bplus_tree_cpu.h"
#include "functions.h"
#include "sort_strings.cuh"
#include <helper_cuda.h>
#include "gpu_test.cuh"

using namespace std;

int main(const int argc, char **argv)
{
	findCudaDevice(argc, const_cast<const char **>(argv));

	int* test;//initialization to improve time testing accuracy
	if (cudaMalloc(&test, 4 * 4))
		return 0;

	test_gpu_tree<uint64_t, 4, 1>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 8, 1>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 16, 1>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 32, 1>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 512, 2>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 1024, 2>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 2048, 2>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 4096, 2>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 8192, 2>("dictionary_clean.txt", "oliverTwist.txt");
	test_gpu_tree<uint64_t, 16384, 2>("dictionary_clean.txt", "oliverTwist.txt");
	test_array_searching_book("dictionary_clean.txt", "oliverTwist.txt");
	test_array_searching_book("dictionary_clean.txt", "oliverTwist.txt");
	return 0;
	test_array_searching_book("dictionary.txt", "book.txt");

	cout << "Randoms" << endl;
	test_random_strings();

	cout << "Moby Dick" << endl;
	test_book("book.txt");
}
