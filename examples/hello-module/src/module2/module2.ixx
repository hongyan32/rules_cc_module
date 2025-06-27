export module module2;

#include "module2/header_only.hpp"  // Include traditional header file

export import :part;

export int subtract(int a, int b);

// Export functions that use the header-only class
export template<typename T>
T header_add(T a, T b) {
    return HeaderOnlyClass<T>::add(a, b);
}

export template<typename T>
T header_multiply(T a, T b) {
    return HeaderOnlyClass<T>::multiply(a, b);
}

export int header_square(int x) {
    return square(x);
}
