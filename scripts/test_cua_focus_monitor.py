import unittest
from report_cua_focus import classify, report

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

class FocusReportTests(unittest.TestCase):
    def test_final_action_tail_is_included_but_unrelated_idle_is_excluded(self):
        events = [
            {'timestamp': '2026-10-24T00:00:00Z', 'kind': 'tool_call', 'step': 1,
             'body': '[trycua] browser_click\n{"pid":2,"window_id":20}'},
            {'timestamp': '2026-10-24T00:00:01Z', 'kind': 'tool_result', 'step': 1, 'body': 'ok'}]
        rows = [
            {'time': '2026-10-24T00:00:00Z', 'pid': 1, 'window': 10},
            {'time': '2026-10-24T00:00:00.5Z', 'pid': 1, 'window': 10},
            {'time': '2026-10-24T00:00:01.5Z', 'pid': 2, 'window': 20},
            {'time': '2026-10-24T00:00:04Z', 'pid': 1, 'window': 10}]
        result = report(rows, events)
        self.assertEqual(result['samples_during_command'], 1)
        self.assertEqual(result['samples_after_command'], 1)
        self.assertEqual(len(result['changes']), 1)
        self.assertEqual(result['changes'][0]['classification'], 'suspected_driver_target_activation')
        self.assertEqual(result['changes'][0]['nearby_actions'], ['browser_click'])
        # Observation-only commands do not gain an action tail.
        events[0]['body'] = '[trycua] get_browser_state\n{"pid":2,"window_id":20}'
        self.assertEqual(report(rows, events)['changes'], [])
        self.assertEqual(report(rows, events)['samples_after_command'], 0)

    def test_empty_monitor_or_trace_is_reportable(self):
        self.assertEqual(report([], [])['changes'], [])

if __name__ == '__main__': unittest.main()
