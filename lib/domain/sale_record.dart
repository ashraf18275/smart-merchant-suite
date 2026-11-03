class SaleRecord {
  const SaleRecord({
    required this.id,
    required this.totalMinor,
    required this.paidMinor,
    required this.createdAt,
    required this.itemCount,
    this.warehouseName,
    this.branchName,
  });

  final int id;
  final int totalMinor;
  final int paidMinor;
  final DateTime createdAt;
  final int itemCount;
  final String? warehouseName;
  final String? branchName;

  int get remainingMinor => totalMinor - paidMinor;
}
