// SPDX-License-Identifier: LGPL-2.1-or-later
// SPDX-FileCopyrightText: 2026 Shotwell contributors

void grants_under_the_limit() {
    var budget = new ByteBudget(100);
    budget.acquire(40);
    budget.acquire(60);
    assert(budget.get_held() == 100);
    budget.release(100);
    assert(budget.get_held() == 0);
}

void grants_a_request_that_is_larger_than_the_limit_when_nothing_is_held() {
    var budget = new ByteBudget(100);
    budget.acquire(500);
    assert(budget.get_held() == 500);
    budget.release(500);
    assert(budget.get_held() == 0);
}

void blocks_until_enough_is_released() {
    var budget = new ByteBudget(100);
    budget.acquire(80);

    int64 granted_at_us = 0;
    var thread = new Thread<bool>("producer", () => {
        budget.acquire(50);
        granted_at_us = get_monotonic_time();
        return true;
    });

    // the producer has to wait: 80 + 50 is over the limit
    Thread.usleep(200 * 1000);
    assert(granted_at_us == 0);
    assert(budget.get_held() == 80);

    int64 released_at_us = get_monotonic_time();
    budget.release(80);
    thread.join();

    assert(granted_at_us >= released_at_us);
    assert(budget.get_held() == 50);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/under-the-limit", grants_under_the_limit);
    Test.add_func("/larger-than-the-limit", grants_a_request_that_is_larger_than_the_limit_when_nothing_is_held);
    Test.add_func("/blocks-until-released", blocks_until_enough_is_released);

    return Test.run();
}
