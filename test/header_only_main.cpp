#include <iostream>
#include "header_only_test.h"

int main() {
    HeaderOnlyClass<int> calc;
    
    std::cout << "5 + 3 = " << calc.add(5, 3) << std::endl;
    std::cout << "5 * 3 = " << calc.multiply(5, 3) << std::endl;
    std::cout << "square(4) = " << square(4) << std::endl;
    
    return 0;
}
