import '../../domain/branch.dart';
import '../../domain/expense_record.dart';
import '../../domain/profit_summary.dart';
import '../../domain/payment_method.dart';

abstract interface class ExpenseService {
  Future<List<Branch>> branches();
  Future<int> add({required String description, required String category, required int amountMinor, required int branchId, String paymentMethod = PaymentMethod.cash});
  Future<List<ExpenseRecord>> all({required int branchId, DateTime? from, DateTime? to});
  Future<ProfitSummary> summary({required int branchId, DateTime? from, DateTime? to});
}
