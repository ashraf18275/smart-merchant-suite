import '../../domain/expense_record.dart';
import '../../domain/profit_summary.dart';

abstract interface class ExpenseStore {
  Future<int> add({
    required String description,
    required String category,
    required int amountMinor,
  });

  Future<List<ExpenseRecord>> all({DateTime? from, DateTime? to});

  Future<ProfitSummary> summary({DateTime? from, DateTime? to});
}
