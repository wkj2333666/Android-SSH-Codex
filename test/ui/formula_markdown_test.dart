import 'package:android_ssh_codex/src/ui/widgets/markdown_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _render(WidgetTester tester, String text) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: MarkdownContent(text: text)),
    ),
  );
}

void main() {
  testWidgets('Markdown typesets common inline and block math delimiters', (
    tester,
  ) async {
    await _render(tester, r'''
行内：\(\sqrt{x}\) 和 $\alpha_1$。

$$\frac{1}{2}$$

\[\frac{x}{y}\]

$$
\sum_{i=1}^n i
$$

\[
\begin{aligned}
x &= \frac{1}{2}\\
y &= \sqrt{x}
\end{aligned}
\]
''');

    final formulas = tester.widgetList<Math>(find.byType(Math)).toList();
    expect(formulas, hasLength(6));
    expect(formulas.map((formula) => formula.parseError), everyElement(isNull));
    expect(
      formulas.take(2).map((formula) => formula.mathStyle),
      everyElement(MathStyle.text),
    );
    expect(
      formulas.skip(2).map((formula) => formula.mathStyle),
      everyElement(MathStyle.display),
    );
    expect(find.textContaining(r'\begin{aligned}'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incomplete math leaves surrounding Markdown intact', (
    tester,
  ) async {
    const incomplete = r'''
\[
\frac{1}{2}

**Further explanation**
''';

    await _render(tester, incomplete);
    expect(find.byType(Math), findsNothing);
    expect(find.text('Further explanation'), findsOneWidget);

    await _render(tester, incomplete.replaceFirst('\n\n', '\n\\]\n\n'));
    expect(find.byType(Math), findsOneWidget);
    expect(find.text('Further explanation'), findsOneWidget);
  });

  testWidgets('named operators do not consume delimiters or spacing',
      (tester) async {
    const formulas = [
      r'\operatorname{clip}\left(\frac{x}{y},0,1\right)',
      r'\operatorname{clip}\bigl(x,0,1\bigr)',
      r'\operatorname{平均}_{t\in W}\left[x_t\right]',
      r'\boxed{\operatorname{mean}_{j}\!\left[P_j\right]}',
    ];
    await _render(
      tester,
      [
        r'\(' + formulas.first + r'\)',
        for (final source in formulas.skip(1)) r'\[' + source + r'\]',
      ].join('\n\n'),
    );

    final math = tester.widgetList<Math>(find.byType(Math)).toList();
    expect(math, hasLength(formulas.length));
    expect(math.map((formula) => formula.parseError), everyElement(isNull));
    expect(math.first.mathStyle, MathStyle.text);
    expect(math.skip(1).map((formula) => formula.mathStyle),
        everyElement(MathStyle.display));
    for (final formula in formulas) {
      expect(find.text(formula), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported LaTeX falls back without parsing code or prices', (
    tester,
  ) async {
    const source = r'\notACodexMathCommand{x}';
    await _render(
      tester,
      r'Prices are $5 and $10. Code: `$x^2$`'
      '\n\n'
      r'$$'
      '$source'
      r'$$',
    );

    expect(find.byType(Math), findsOneWidget);
    expect(find.text(source), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide formulas scroll horizontally without overflowing',
      (tester) async {
    final expression = List.filled(30, r'\frac{a}{b}').join(' + ');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 180,
          child: MarkdownContent(text: '\\[$expression\\]'),
        ),
      ),
    ));

    final scrollable = find.byType(Scrollable);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(scrollable, const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
