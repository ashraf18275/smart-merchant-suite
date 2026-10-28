class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.totalMinor,
    required this.paidMinor,
    required this.createdAt,
    required this.itemCount,
  });

  final int id;
  final int totalMinor;
  final int paidMinor;
  final DateTime createdAt;
  final int itemCount;

  int get remainingMinor => totalMinor - paidMinor;
}
