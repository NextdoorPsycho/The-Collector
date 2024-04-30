import 'package:fast_log/fast_log.dart';
import 'package:flutter/material.dart';

class HubDice extends StatefulWidget {
  const HubDice({
    super.key,
  });

  @override
  _HubDiceState createState() => _HubDiceState();
}

class _HubDiceState extends State<HubDice> {
  bool _isCommanderExpanded = true;
  bool _isStandardExpanded = true;

  final Map<String, Function> _navigationMap = {
    '2 Player Commander': () {
      info('Navigate to 2 Player Commander');
    },
    '4 Player Commander': () {
      info('Navigate to 4 Player Commander');
    },
    '6 Player Commander': () {
      info('Navigate to 6 Player Commander');
    },
    '8 Player Commander': () {
      info('Navigate to 8 Player Commander');
    },
    '2 Player Standard': () {
      info('Navigate to 2 Player Standard');
    },
    '3 Player Standard': () {
      info('Navigate to 3 Player Standard');
    },
    '4 Player Standard': () {
      info('Navigate to 4 Player Standard');
    },
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Modes'),
      ),
      body: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          children: [
            ExpansionPanelList(
              expansionCallback: (int index, bool isExpanded) {
                setState(() {
                  if (index == 0) {
                    _isCommanderExpanded = !_isCommanderExpanded;
                  } else if (index == 1) {
                    _isStandardExpanded = !_isStandardExpanded;
                  }
                });
              },
              children: [
                ExpansionPanel(
                  headerBuilder: (BuildContext context, bool isExpanded) {
                    return const ListTile(
                      title: Text('Commander'),
                    );
                  },
                  body: GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 2,
                    children: [
                      _buildGridItem('2 Player Commander'),
                      _buildGridItem('4 Player Commander'),
                      _buildGridItem('6 Player Commander'),
                      _buildGridItem('8 Player Commander'),
                    ],
                  ),
                  isExpanded: _isCommanderExpanded,
                ),
                ExpansionPanel(
                  headerBuilder: (BuildContext context, bool isExpanded) {
                    return const ListTile(
                      title: Text('Standard'),
                    );
                  },
                  body: GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 2,
                    children: [
                      _buildGridItem('2 Player Standard'),
                      _buildGridItem('3 Player Standard'),
                      _buildGridItem('4 Player Standard'),
                    ],
                  ),
                  isExpanded: _isStandardExpanded,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridItem(String title) {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.40),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: () {
          if (_navigationMap.containsKey(title)) {
            _navigationMap[title]!();
          }
        },
        child: Center(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
      ),
    );
  }
}
