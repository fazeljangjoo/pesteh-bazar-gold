import 'package:flutter_test/flutter_test.dart';
import 'package:pesteh_bazar/buy_mode_ui.dart';
import 'package:pesteh_bazar/pricing_engine.dart';
import 'package:pesteh_bazar/workshop_calc.dart';

void main() {
  test('abkhandan shortage ⇒ negative moisture', () {
    final WsMoisture m = wsMoisture(1000, 970)!;
    expect(m.shortage, isTrue);
    expect(m.absKg, closeTo(30, 1e-9));
    expect(m.pct, closeTo(-3, 1e-9)); // 30 × 100 ÷ 1000
  });

  test('abkhandan added weight ⇒ positive moisture', () {
    final WsMoisture m = wsMoisture(800, 840)!;
    expect(m.added, isTrue);
    expect(m.absKg, closeTo(40, 1e-9));
    expect(m.pct, closeTo(5, 1e-9));
  });

  test('weighted ounce/gram average over lots', () {
    final List<Map<String, num?>> rows = <Map<String, num?>>[
      <String, num?>{'kg': 100, 'ounce': 28, 'gram': 50},
      <String, num?>{'kg': 300, 'ounce': 32, 'gram': null},
    ];
    expect(wsWeightedAvg(rows, 'ounce'), closeTo(31, 1e-9));
    expect(wsWeightedAvg(rows, 'gram'), closeTo(50, 1e-9));
  });

  test('base50: fee ÷ 50 × gram', () {
    expect(buyModeEffective(BuyMode.base50, 1000000, 46, 50), closeTo(920000, 1e-6));
  });

  test('per gram: fee × gram; base50 shown = fee × 50; engine agrees', () {
    expect(buyModeEffective(BuyMode.perGram, 20000, 46, 50), closeTo(920000, 1e-6));
    expect(buyModeEngineValue(BuyMode.perGram, 20000, 50), 1000000);
    final PriceBlendResult r = priceBlend(<String, dynamic>{
      'base_price': buyModeEngineValue(BuyMode.perGram, 20000, 50),
      'weight_kg': 10,
      'ref_gram': 50,
      'items': <dynamic>[],
      'base_gram_mode': true,
      'base_g': 46,
    });
    expect(r.avgPerKg, 920000);
  });
}
