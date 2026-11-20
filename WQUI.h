//
//  WQUI.h
//  WQ Files shared UI helpers
//

#import <UIKit/UIKit.h>
#import "WQLocalization.h"

NS_ASSUME_NONNULL_BEGIN
@protocol CHSearchable <UISearchResultsUpdating>
@property (nonatomic, readonly) UISearchController *contextSearchController;
@end
@protocol CHContextAlertPresentation <NSObject>
- (BOOL)presentContextAlert:(UIAlertController *)alert from:(UIViewController *)host;
@end


// Respect smaller system text sizes and cap application text at normal (Large).
void wq_configure_window(UIWindow *window);
UIFont *wq_font(UIFontTextStyle style, UITraitCollection *traits);
void wq_prepare_list(UITableViewController *host, NSString *title);
void wq_empty_message(UITableView *table, NSString *_Nullable message, float fraction);
UIBarButtonItem *wq_refresh_button(id target, SEL action, BOOL enabled);

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
void wq_present_confirmation(UIViewController *host, UIAlertController *alert);
// title/message/action titles are localization keys. Pass already-localized
// text and raw data (names, keys, error strings) as WQVerbatim(text) so it is
// shown exactly and never looked up a second time.
UIAlertController *wq_alert_controller(NSString *_Nullable title, NSString *_Nullable message, UIAlertControllerStyle style);
UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^_Nullable handler)(UIAlertAction *));
NSString *wq_size_text(unsigned long long size);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);
// Mutations use the serial I/O queue. Scans yield to that queue between steps.
void wq_scan_lifecycle_install(void);
void wq_scan_pause_for_background(void);
dispatch_queue_t wq_scan_queue(void);
void wq_scan_read(void (^work)(void));
@interface WQProgressHeaderView : UITableViewHeaderFooterView
- (void)setText:(nullable NSString *)text fraction:(float)fraction;
@end
void wq_offer_access_recovery(UIViewController *host);
BOOL wq_begin_mutation(UIViewController *host);
void wq_end_mutation(void);
NS_ASSUME_NONNULL_END
