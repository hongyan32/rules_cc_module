export module header_only_module;

export template<typename T>
T power(T base, int exp) {
    T result = 1;
    for (int i = 0; i < exp; ++i) {
        result *= base;
    }
    return result;
}

export inline double pi() {
    return 3.14159265359;
}
