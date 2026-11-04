import '../../core/app_error.dart';
import '../../domain/expense_record.dart';
import '../../domain/profit_summary.dart';
import '../../domain/payment_method.dart';
import '../ports/expense_service.dart';
import '../ports/expense_store.dart';

class ExpenseApplicationService implements ExpenseService {
  ExpenseApplicationService(this._store);

  final ExpenseStore _store;

  @override
  Future<int> add({
    required String description,
    required String category,
    required int amountMinor,
    String paymentMethod = PaymentMethod.cash,
  }) async {
    if (description.trim().isEmpty) throw AppException('وصف المصروف مطلوب');
    if (category.trim().isEmpty) throw AppException('تصنيف المصروف مطلوب');
    if (amountMinor <= 0) {
      throw AppException('قيمة المصروف يجب أن تكون أكبر من صفر');
    }
    if (!PaymentMethod.isValid(paymentMethod)) {
      throw AppException('طريقة الدفع المحددة غير مدعومة');
    }
    return _store.add(
      description: description,
      category: category,
      amountMinor: amountMinor,
      paymentMethod: paymentMethod,
    );
  }

  @override
  Future<List<ExpenseRecord>> all({DateTime? from, DateTime? to}) async {
    _validateDateRange(from, to);
    return await _store.all(from: from, to: to);
  }

  @override
  Future<ProfitSummary> summary({DateTime? from, DateTime? to}) async {
    _validateDateRange(from, to);
    return await _store.summary(from: from, to: to);
  }

  void _validateDateRange(DateTime? from, DateTime? to) {
    if (from != null && to != null && from.isAfter(to)) {
      throw AppException('تاريخ البداية يجب ألا يتجاوز تاريخ النهاية');
    }
  }
}
