#include <iostream>
import header_only_module;

int main() {
    std::cout << "2^8 = " << power(2, 8) << std::endl;
    std::cout << "3.5^3 = " << power(3.5, 3) << std::endl;
    std::cout << "pi = " << pi() << std::endl;
    
    return 0;
}
