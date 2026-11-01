class Warehouse {
  const Warehouse({
    required this.id,
    required this.branchId,
    required this.branchName,
    required this.name,
    required this.isActive,
  });

  final int id;
  final int branchId;
  final String branchName;
  final String name;
  final bool isActive;
}
