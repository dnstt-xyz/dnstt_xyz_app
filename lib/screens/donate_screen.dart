import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class DonateScreen extends StatelessWidget {
  const DonateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Support Us'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Icon(
                      Icons.favorite,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Support Internet Freedom',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Your donation helps us improve this app and bring more servers online for internet freedom. Every contribution makes a difference!',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.grey[600],
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildWalletCard(
              context,
              'USDT (Tron/TRC20)',
              'TMBF7T8BpLhSkpauNUzcFHmHSEYL1Ucq5X',
              Icons.attach_money,
              Colors.red,
            ),
            const SizedBox(height: 12),
            _buildWalletCard(
              context,
              'USDT (Ethereum)',
              '0xD2c70A2518E928cFeAF749Db39E67e073dB3E59a',
              Icons.attach_money,
              Colors.teal,
            ),
            const SizedBox(height: 12),
            _buildWalletCard(
              context,
              'USDC (Ethereum)',
              '0xD2c70A2518E928cFeAF749Db39E67e073dB3E59a',
              Icons.monetization_on,
              Colors.blue,
            ),
            const SizedBox(height: 12),
            _buildWalletCard(
              context,
              'Bitcoin (BTC)',
              'bc1q770vn8d65tq0jdh0zm4qkl7j47m6has0e2pkg6',
              Icons.currency_bitcoin,
              Colors.orange,
            ),
            const SizedBox(height: 12),
            _buildWalletCard(
              context,
              'Solana (SOL)',
              '2hhrPoRocPHrWLYW7a7kENu3ZS2rXpBBCmaCfBsd9wdo',
              Icons.sunny,
              Colors.green,
            ),
            const SizedBox(height: 24),
            Text(
              'Tap any address to copy',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Card(
              child: InkWell(
                onTap: () async {
                  final url = Uri.parse('https://dnstt.xyz');
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.language, color: Colors.blue[600]),
                      const SizedBox(width: 8),
                      Text(
                        'dnstt.xyz',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue[600],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.open_in_new, color: Colors.blue[600], size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletCard(
    BuildContext context,
    String name,
    String address,
    IconData icon,
    Color color,
  ) {
    return Card(
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: address));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$name address copied!'),
              duration: const Duration(seconds: 2),
              backgroundColor: color,
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      address,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.copy, color: Colors.grey[400], size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
