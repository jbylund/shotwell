// SPDX-FileCopyrightText: Software Freedom Conservancy Inc.
// SPDX-License-Identifier: LGPL-2.1-or-later

// Items are ordered by key, then by tie, so every item has a place and the sorted order is unique.
class Item : Object {
    public int key;
    public int tie;

    public Item(int key, int tie) {
        this.key = key;
        this.tie = tie;
    }
}

int64 item_comparator(void *a, void *b) {
    Item *x = (Item *) a;
    Item *y = (Item *) b;

    if (x->key != y->key)
        return (x->key < y->key) ? -1 : 1;

    return x->tie - y->tie;
}

// A comparator that sorts the other way, ties included
int64 item_comparator_descending(void *a, void *b) {
    return -item_comparator(a, b);
}

Gee.ArrayList<Item> make_items(int count, int distinct_keys) {
    Rand rand = new Rand.with_seed(count + distinct_keys);
    Gee.ArrayList<Item> items = new Gee.ArrayList<Item>();
    for (int ctr = 0; ctr < count; ctr++)
        items.add(new Item(rand.int_range(0, distinct_keys), ctr));

    return items;
}

void shuffle(Gee.ArrayList<Item> items, uint32 seed) {
    Rand rand = new Rand.with_seed((int32) seed);
    for (int ctr = items.size - 1; ctr > 0; ctr--) {
        int other = rand.int_range(0, ctr + 1);
        Item tmp = items[ctr];
        items[ctr] = items[other];
        items[other] = tmp;
    }
}

Gee.ArrayList<Item> reference_order(Gee.ArrayList<Item> items, Comparator cmp) {
    Gee.ArrayList<Item> copy = new Gee.ArrayList<Item>();
    copy.add_all(items);
    copy.sort((a, b) => { return (int) cmp(a, b); });

    return copy;
}

void assert_same_order(SortedList<Item> list, Gee.ArrayList<Item> expected) {
    assert(list.size == expected.size);
    for (int ctr = 0; ctr < expected.size; ctr++)
        assert(list.get_at(ctr) == expected[ctr]);
}

void add_resort_tests() {
    Test.add_func("/sorted_list/resort", () => {
        foreach (int count in new int[] { 0, 1, 2, 3, 10, 257, 2000 }) {
            Gee.ArrayList<Item> items = make_items(count, 7);
            Gee.ArrayList<Item> expected = reference_order(items, item_comparator);

            // an unsorted list that gets a comparator
            SortedList<Item> list = new SortedList<Item>();
            list.add_all(items);
            list.resort(item_comparator);
            assert_same_order(list, expected);

            // a list that is already in order, and one in exactly the opposite order
            list.resort(item_comparator);
            assert_same_order(list, expected);
            list.resort(item_comparator_descending);
            Gee.ArrayList<Item> backwards = new Gee.ArrayList<Item>();
            for (int ctr = expected.size - 1; ctr >= 0; ctr--)
                backwards.add(expected[ctr]);
            assert_same_order(list, backwards);
        }
    });

    Test.add_func("/sorted_list/add_all_keeps_order", () => {
        Gee.ArrayList<Item> items = make_items(1500, 40);
        Gee.ArrayList<Item> expected = reference_order(items, item_comparator);

        // everything at once, in batches, one by one, and a batch added to a sorted list
        SortedList<Item> at_once = new SortedList<Item>(item_comparator);
        at_once.add_all(items);
        assert_same_order(at_once, expected);

        SortedList<Item> batches = new SortedList<Item>(item_comparator);
        for (int start = 0; start < items.size; start += 100)
            batches.add_all(items.slice(start, int.min(start + 100, items.size)));
        assert_same_order(batches, expected);

        SortedList<Item> one_by_one = new SortedList<Item>(item_comparator);
        foreach (Item item in items)
            one_by_one.add(item);
        assert_same_order(one_by_one, expected);

        SortedList<Item> tail = new SortedList<Item>(item_comparator);
        tail.add_all(items.slice(0, 1400));
        tail.add_all(items.slice(1400, 1500));
        assert_same_order(tail, expected);
    });
}

// Sorting moves items around as plain pointers; the sort must leave the references to every
// item exactly as they were.
void add_reference_tests() {
    Test.add_func("/sorted_list/reference_counts", () => {
        Gee.ArrayList<Item> items = make_items(3000, 11);
        shuffle(items, 9);
        uint[] before = new uint[items.size];
        for (int ctr = 0; ctr < items.size; ctr++)
            before[ctr] = items[ctr].ref_count;

        SortedList<Item> list = new SortedList<Item>();
        list.add_all(items);
        uint[] with_list = new uint[items.size];
        for (int ctr = 0; ctr < items.size; ctr++) {
            with_list[ctr] = items[ctr].ref_count;
            assert(with_list[ctr] == before[ctr] + 1);
        }

        // sort, sort again, sort the other way, add a batch to a sorted list, reverse
        list.resort(item_comparator);
        list.resort(item_comparator);
        list.resort(item_comparator_descending);
        list.resort(item_comparator);
        list.reverse();
        list.reverse();
        for (int ctr = 0; ctr < items.size; ctr++)
            assert(items[ctr].ref_count == with_list[ctr]);

        SortedList<Item> batches = new SortedList<Item>(item_comparator);
        batches.add_all(items.slice(0, 2000));
        batches.add_all(items.slice(2000, 3000));
        for (int ctr = 0; ctr < items.size; ctr++)
            assert(items[ctr].ref_count == with_list[ctr] + 1);

        // dropping the lists gives the references back
        list = null;
        batches = null;
        for (int ctr = 0; ctr < items.size; ctr++)
            assert(items[ctr].ref_count == before[ctr]);
    });
}

void add_reverse_tests() {
    Test.add_func("/sorted_list/reverse", () => {
        foreach (int count in new int[] { 0, 1, 2, 3, 4, 257, 1000 }) {
            Gee.ArrayList<Item> items = make_items(count, 5);
            shuffle(items, 5);
            SortedList<Item> list = new SortedList<Item>(item_comparator);
            list.add_all(items);
            Gee.ArrayList<Item> ascending = reference_order(items, item_comparator);
            Gee.ArrayList<Item> descending = reference_order(items, item_comparator_descending);

            list.reverse();
            assert_same_order(list, descending);

            list.reverse();
            assert_same_order(list, ascending);
        }
    });
}

void main(string[] args) {
    Test.init(ref args);
    add_resort_tests();
    add_reverse_tests();
    add_reference_tests();
    Test.run();
}
