class ExpenseRecord {
  const ExpenseRecord({
    required this.id,
    required this.description,
    required this.category,
    required this.amountMinor,
    required this.createdAt,
  });

  final int id;
  final String description;
  final String category;
  final int amountMinor;
  final DateTime createdAt;
}
