import std.compat;
import module1;
import module2;
import module3;

using namespace std;
int main() {
    std::cout << "add(1, 2) = " << add(1, 2) << std::endl;
    std::cout << "subtract(1, 2) = " << subtract(1, 2) << std::endl;
    std::cout << "get_message() = " << get_message() << std::endl;
    std::cout << "multiply_and_add(5, 2, 3) = " << multiply_and_add(5, 2, 3) << std::endl;
    return 0;
}
