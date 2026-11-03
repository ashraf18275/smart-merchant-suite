class ProductUnit {
  const ProductUnit({
    required this.id,
    required this.name,
    required this.abbreviation,
    required this.allowsFraction,
    required this.isActive,
  });

  final int id;
  final String name;
  final String abbreviation;
  final bool allowsFraction;
  final bool isActive;
}
