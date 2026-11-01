class Branch {
  const Branch({
    required this.id,
    required this.name,
    this.address,
    this.phone,
    required this.isActive,
  });

  final int id;
  final String name;
  final String? address;
  final String? phone;
  final bool isActive;
}
