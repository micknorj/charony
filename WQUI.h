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


static inline UIBarButtonItemStyle wq_primary_button_style(void)
{
    if (@available(iOS 26.0, *)) return UIBarButtonItemStyleProminent;
    return UIBarButtonItemStylePlain;
}

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
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
