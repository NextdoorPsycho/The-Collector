import 'package:flutter/material.dart';
import 'package:pandabar/pandabar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CommanderTwoPlayerHealth extends StatefulWidget {
  const CommanderTwoPlayerHealth({super.key});

  @override
  CommanderTwoPlayerHealthState createState() =>
      CommanderTwoPlayerHealthState();
}

class CommanderTwoPlayerHealthState extends State<CommanderTwoPlayerHealth> {
  int _player1Health = 40;
  int _player2Health = 40;

  @override
  void initState() {
    super.initState();
    _loadHealth();
  }

  void _loadHealth() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _player1Health = prefs.getInt('player1Health') ?? 40;
      _player2Health = prefs.getInt('player2Health') ?? 40;
    });
  }

  void _saveHealth() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('player1Health', _player1Health);
    await prefs.setInt('player2Health', _player2Health);
  }

  void _incrementHealth(int player, int amount) {
    setState(() {
      if (player == 1) {
        _player1Health += amount;
      } else {
        _player2Health += amount;
      }
      _saveHealth();
    });
  }

  void _resetHealth(int player) {
    setState(() {
      if (player == 1) {
        _player1Health = 40;
      } else {
        _player2Health = 40;
      }
      _saveHealth();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Transform.rotate(
              angle: 3.14159, // Rotate 180 degrees (upside down)
              child: _buildPlayerSection(2),
            ),
          ),
          Expanded(
            child: _buildPlayerSection(1),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerSection(int player) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onLongPress: () => _resetHealth(player),
          child: Text(
            player == 1 ? '$_player1Health' : '$_player2Health',
            style: const TextStyle(fontSize: 48),
          ),
        ),
        const SizedBox(height: 16),
        PandaBar(
          buttonData: [
            PandaBarButtonData(id: '0', icon: Icons.add, title: '+10'),
            PandaBarButtonData(id: '1', icon: Icons.add, title: '+1'),
            PandaBarButtonData(id: '2', icon: Icons.refresh, title: 'Reset'),
            PandaBarButtonData(id: '3', icon: Icons.remove, title: '-1'),
            PandaBarButtonData(id: '4', icon: Icons.remove, title: '-10'),
          ],
          onChange: (id) {
            int amount = 0;
            switch (id) {
              case '0':
                amount = 10;
                break;
              case '1':
                amount = 1;
                break;
              case '3':
                amount = -1;
                break;
              case '4':
                amount = -10;
                break;
            }
            _incrementHealth(player, amount);
          },
        ),
      ],
    );
  }
}
