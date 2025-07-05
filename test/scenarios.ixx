module;
#include "scenarios_impl.h"
#include <string>
#include <iostream>;

export module scenarios;



// =================================================================
// ===== 情况 1: 模板函数调用特化的模板函数
// =================================================================

// 外部模板函数
export template<typename T>
void scenario1_entry(T val) {
    std::cout << "Executing Scenario 1 with " << typeid(T).name() << ":\n";
    inner_func(val);
}


// =================================================================
// ===== 情况 2: 模板函数使用特化的模板类
// =================================================================

// 外部模板函数
export template<typename T>
void scenario2_entry(T val) {
    std::cout << "Executing Scenario 2 with " << typeid(T).name() << ":\n";
    FullClassHelper<T> helper;
    helper.do_work();
}






// =================================================================
// ===== 情况 3: 模板函数使用模板类，但只特化其方法
// 当导出这个函数的时候，这个函数关联的MemberHelper也能被隐式导出
// 但是MemberHelper的do_work方法的特化不会被导出
// C++ 语法不允许我们 export 一个成员函数的特化。我们只能 export 整个类或整个类特化
// 唯一的办法式实例化一个string特化的调用，这样string特化的链就被保留下来了
// =================================================================
// 外部模板函数
export template<typename T>
void scenario3_entry(T val) {
    std::cout << "Executing Scenario 3 with—— " << typeid(T).name() << ":\n";
    MemberHelper<T> helper;
    helper.do_work();
}

// 显式实例化 string 特化的函数, 由于前面的export，这个也会生成，然后就保留了特化的链条
template void scenario3_entry<std::string>(std::string val);


export template<typename T, typename V>
void scenario4_entry(T tpl, V val) {
    std::cout << "Executing Scenario 4 with—— " << typeid(V).name() << ":\n";
    TplMemberHelper<T> helper(tpl);
    helper.do_work(val);
}
