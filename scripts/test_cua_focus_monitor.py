import unittest
from report_cua_focus import classify

class FocusPolicyTests(unittest.TestCase):
    def classify(self, pid, window, ages=None, action=True):
        return classify({'pid': 1, 'window': 10},
                        {'pid': pid, 'window': window, 'hardware_event_ages': ages or {}},
                        {2}, {(2, 20)}, action)
    def test_unrelated_user_window_switch_is_not_a_driver_violation(self):
        self.assertEqual(self.classify(3, 30), 'unrelated_foreground_change')
        self.assertEqual(self.classify(1, 11), 'unrelated_foreground_change')
    def test_target_click_is_correlated_not_proven_safe(self):
        self.assertEqual(self.classify(2, 20, {'left_mouse_down': .1}), 'target_change_with_recent_user_input')
    def test_target_activation_near_action_is_suspected(self):
        self.assertEqual(self.classify(2, 20), 'suspected_driver_target_activation')
        self.assertEqual(self.classify(2, 21), 'suspected_driver_target_app_activation')
    def test_typing_does_not_excuse_an_activation(self):
        self.assertEqual(self.classify(2, 20, {'key_down': .1}), 'suspected_driver_target_activation')
    def test_idle_target_activation_remains_unattributed(self):
        self.assertEqual(self.classify(2, 20, action=False), 'unattributed_target_change')
    def test_same_app_window_order_is_not_app_activation(self):
        self.assertEqual(classify({'pid': 2, 'window': 21}, {'pid': 2, 'window': 20}, {2}, {(2,20)}, True), 'suspected_target_window_raise')
    def test_unchanged_focus_is_not_a_transition(self):
        self.assertIsNone(self.classify(1, 10))

if __name__ == '__main__': unittest.main()
