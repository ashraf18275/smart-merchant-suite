class ProfitSummary {
  const ProfitSummary({
    required this.salesMinor,
    required this.costOfGoodsMinor,
    required this.expensesMinor,
  });

  final int salesMinor;
  final int costOfGoodsMinor;
  final int expensesMinor;

  int get grossProfitMinor => salesMinor - costOfGoodsMinor;
  int get netProfitMinor => grossProfitMinor - expensesMinor;
}
