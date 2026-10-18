import 'package:bee_sync/bee_sync.dart';
import 'package:flutter/material.dart';

import 'analytics.dart';

class Product {
  const Product(this.id, this.name, this.price, this.icon, this.color);

  final String id;
  final String name;
  final double price;
  final IconData icon;
  final Color color;
}

const catalog = [
  Product('p01', 'Honey jar', 6.5, Icons.emoji_food_beverage, Colors.amber),
  Product(
    'p02',
    'Beeswax candle',
    9,
    Icons.local_fire_department,
    Colors.orange,
  ),
  Product('p03', 'Garden gloves', 12, Icons.back_hand, Colors.green),
  Product('p04', 'Flower seeds', 3.2, Icons.local_florist, Colors.pink),
  Product('p05', 'Bee hotel', 24, Icons.house_siding, Colors.brown),
  Product('p06', 'Watering can', 15, Icons.water_drop, Colors.blue),
  Product('p07', 'Lavender soap', 5.5, Icons.soap, Colors.purple),
  Product(
    'p08',
    'Pollen granola',
    7.8,
    Icons.breakfast_dining,
    Colors.deepOrange,
  ),
  Product('p09', 'Hive tool', 11, Icons.handyman, Colors.blueGrey),
  Product('p10', 'Smoker', 32, Icons.cloud, Colors.grey),
  Product('p11', 'Veil hat', 19, Icons.face, Colors.teal),
  Product('p12', 'Propolis drops', 13.5, Icons.medication_liquid, Colors.red),
  Product('p13', 'Honey dipper', 4, Icons.restaurant, Colors.lime),
  Product('p14', 'Mead kit', 39, Icons.wine_bar, Colors.indigo),
  Product('p15', 'Wildflower tea', 6, Icons.local_cafe, Colors.lightGreen),
  Product('p16', 'Field guide', 17, Icons.menu_book, Colors.cyan),
];

/// The cart, shared by the shop and cart tabs.
class Cart extends ChangeNotifier {
  final items = <Product>[];

  double get total => items.fold(0, (sum, p) => sum + p.price);

  void add(Product p) {
    items.add(p);
    notifyListeners();
  }

  void clear() {
    items.clear();
    notifyListeners();
  }
}

/// A promo banner and a lazy product list: each card tracks `widget_viewed`
/// as it scrolls into view.
class ShopScreen extends StatelessWidget {
  const ShopScreen({required this.analytics, required this.cart, super.key});

  final Analytics analytics;
  final Cart cart;

  @override
  Widget build(BuildContext context) => ListView.builder(
    // Build cards only once they're on screen, so a build is a view.
    cacheExtent: 0,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    itemCount: catalog.length + 1,
    itemBuilder: (context, i) {
      if (i == 0) {
        return ViewTracker(
          analytics: analytics,
          widgetName: 'promo_banner',
          id: 'spring_sale',
          child: _PromoBanner(
            onTap: () => analytics.track(
              'promo_tapped',
              properties: {'promo_id': 'spring_sale'},
            ),
          ),
        );
      }
      final p = catalog[i - 1];
      return ViewTracker(
        analytics: analytics,
        widgetName: 'product_card',
        id: p.id,
        properties: {'position': i},
        child: _ProductCard(
          product: p,
          onTap: () {
            analytics.track(
              'product_tapped',
              properties: {'product_id': p.id, 'position': i},
            );
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: 'product_detail'),
                builder: (_) =>
                    ProductScreen(product: p, analytics: analytics, cart: cart),
              ),
            );
          },
        ),
      );
    },
  );
}

class _PromoBanner extends StatelessWidget {
  const _PromoBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.local_offer, color: scheme.onPrimaryContainer),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Spring sale: scroll the list and watch widget_viewed '
                  'events queue up.',
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.onTap});

  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: product.color.withValues(alpha: 0.18),
        child: Icon(product.icon, color: product.color),
      ),
      title: Text(product.name),
      subtitle: Text(product.id),
      trailing: Text(
        '\$${product.price.toStringAsFixed(2)}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      onTap: onTap,
    ),
  );
}

class ProductScreen extends StatelessWidget {
  const ProductScreen({
    required this.product,
    required this.analytics,
    required this.cart,
    super.key,
  });

  final Product product;
  final Analytics analytics;
  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          CircleAvatar(
            radius: 56,
            backgroundColor: p.color.withValues(alpha: 0.18),
            child: Icon(p.icon, size: 56, color: p.color),
          ),
          const SizedBox(height: 24),
          Text(
            p.name,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(
            '\$${p.price.toStringAsFixed(2)}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('Add to cart'),
            onPressed: () {
              cart.add(p);
              analytics.track(
                'add_to_cart',
                properties: {'product_id': p.id, 'price': p.price},
              );
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text('${p.name} added')));
            },
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.bolt),
            label: const Text('Buy now (immediate)'),
            onPressed: () {
              analytics.track(
                'purchase',
                properties: {
                  'order_id': 'o${DateTime.now().millisecondsSinceEpoch}',
                  'total': p.price,
                  'items': [p.id],
                },
                priority: Priority.immediate,
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Purchased: sent right away')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class CartScreen extends StatelessWidget {
  const CartScreen({required this.analytics, required this.cart, super.key});

  final Analytics analytics;
  final Cart cart;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cart,
    builder: (context, _) {
      if (cart.items.isEmpty) {
        return const Center(
          child: Text(
            'Your cart is empty.\nAdd products from the Shop tab.',
            textAlign: TextAlign.center,
          ),
        );
      }
      return Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final p in cart.items)
                  ListTile(
                    leading: Icon(p.icon, color: p.color),
                    title: Text(p.name),
                    trailing: Text('\$${p.price.toStringAsFixed(2)}'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.payment),
              label: Text('Checkout \$${cart.total.toStringAsFixed(2)}'),
              onPressed: () {
                analytics.track(
                  'purchase',
                  properties: {
                    'order_id': 'o${DateTime.now().millisecondsSinceEpoch}',
                    'total': cart.total,
                    'items': [for (final p in cart.items) p.id],
                  },
                  priority: Priority.immediate,
                );
                cart.clear();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Order placed: sent right away'),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
