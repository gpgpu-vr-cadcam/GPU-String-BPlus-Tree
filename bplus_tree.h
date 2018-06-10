#pragma once
#include <vector>

template<class HASH, int B>
class bplus_tree
{
protected:
	static int needed_nodes(int elemNum);

	void virtual create_tree(HASH* keys, int* values, int size) = 0;
public:
	virtual ~bplus_tree() = default;

	bool virtual exist(HASH key) = 0;
	std::vector<bool> virtual exist(HASH* keys, int size) = 0;

	int virtual get_value(HASH key) = 0;
	std::vector<int> virtual get_value(HASH* keys, int size) = 0;

	void virtual insert(HASH key, int value) = 0;

	void virtual bulk_insert(HASH* keys, int* values, int size) = 0;
};

template <class HASH, int B>
int bplus_tree<HASH, B>::needed_nodes(int elemNum)
{
	int pages = 0;
	while (elemNum > B)
	{
		elemNum = elemNum * 2 / B;
		pages += elemNum;
	}
	pages += 1;
	return pages;
}
