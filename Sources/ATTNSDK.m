//
//  CreativeSDK.m
//  test
//
//  Created by Ivan Loughman-Pawelko on 7/19/22.
//

#import <WebKit/WebKit.h>
#import "ATTNAPI.h"
#import "ATTNSDK.h"
#import "ATTNUserIdentity.h"
#import "ATTNCreativeUrlFormatter.h"
#import "Internal/ATTNInfoEvent.h"


// Status passed to ATTNCreativeTriggerCompletionHandler when the creative is opened sucessfully
NSString *const CREATIVE_TRIGGER_STATUS_OPENED = @"CREATIVE_TRIGGER_STATUS_OPENED";
// Status passed to ATTNCreativeTriggerCompletionHandler when the creative is closed sucessfully
NSString *const CREATIVE_TRIGGER_STATUS_CLOSED = @"CREATIVE_TRIGGER_STATUS_CLOSED";
// Status passed to the ATTNCreativeTriggerCompletionHandler when the Creative has been triggered but it is not
// opened successfully. This can happen if there is no available mobile app creative, if the creative
// is fatigued, if the creative call has been timed out, or if an unknown exception occurs.
NSString *const CREATIVE_TRIGGER_STATUS_NOT_OPENED = @"CREATIVE_TRIGGER_STATUS_NOT_OPENED";
// Status passed to the ATTNCreativeTriggerCompletionHandler when the Creative is not closed due to an unknown
// exception
NSString *const CREATIVE_TRIGGER_STATUS_NOT_CLOSED = @"CREATIVE_TRIGGER_STATUS_NOT_CLOSED";


@implementation ATTNSDK {
  UIView *_parentView;
  WKWebView *_webView;
  NSString *_mode;
  ATTNUserIdentity *_userIdentity;
  ATTNAPI *_api;
  ATTNCreativeTriggerCompletionHandler _triggerHandler;
}

- (id)initWithDomain:(NSString *)domain {
  return [self initWithDomain:domain mode:@"production"];
}

- (id)initWithDomain:(NSString *)domain mode:(NSString *)mode {
  if (self = [super init]) {
    self->_domain = domain;
    _mode = mode;
    _userIdentity = [[ATTNUserIdentity alloc] init];
    _api = [[ATTNAPI alloc] initWithDomain:domain];

    [self sendInfoEvent];
  }
  return self;
}

- (void)identify:(NSDictionary *)userIdentifiers {
  if ([userIdentifiers isKindOfClass:[NSString class]]) {
    // accept NSString for backward compatibility
    NSLog(@"WARNING: This way of calling identify is deprecated. Please pass in userIdentifiers as an <NSDictionary *>. See SDK README for details.");
    [_userIdentity mergeIdentifiers:@{IDENTIFIER_TYPE_CLIENT_USER_ID : (NSString *)userIdentifiers}];
  } else if ([userIdentifiers isKindOfClass:[NSDictionary class]]) {
    [_userIdentity mergeIdentifiers:(NSDictionary *)userIdentifiers];
  } else {
    NSLog(@"ERROR: Incorrect type for userIdentifiers; expected type NSDictionary. No identify call will be made.");
    return;
  }

  [_api sendUserIdentity:_userIdentity];
}

- (void)trigger:(UIView *)theView {
  [self trigger:theView handler:nil];
}

- (void)trigger:(UIView *)theView handler:(ATTNCreativeTriggerCompletionHandler)handler {
  _parentView = theView;
  _triggerHandler = handler;

  NSLog(@"Called showWebView in creativeSDK with domain: %@", _domain);
  if (@available(iOS 14, *)) {
    NSLog(@"The iOS version is new enough, continuing to show the Attentive creative.");
  } else {
    NSLog(@"Not showing the Attentive creative because the iOS version is too old.");
    if (self->_triggerHandler != nil) {
      self->_triggerHandler(CREATIVE_TRIGGER_STATUS_NOT_OPENED);
    }
    return;
  }
  NSString *creativePageUrl = [[ATTNCreativeUrlFormatter class]
      buildCompanyCreativeUrlForDomain:_domain
                                  mode:_mode
                          userIdentity:_userIdentity];

  NSLog(@"Requesting creative page url: %@", creativePageUrl);

  NSURL *url = [NSURL URLWithString:creativePageUrl];
  NSURLRequest *request = [NSURLRequest requestWithURL:url];

  WKWebViewConfiguration *wkWebViewConfiguration = [[WKWebViewConfiguration alloc] init];

  [[wkWebViewConfiguration userContentController] addScriptMessageHandler:self name:@"log"];

  NSString *userScriptWithEventListener = @"window.addEventListener('message', (event) => {if (event.data && event.data.__attentive && event.data.__attentive.action === 'CLOSE') {window.webkit.messageHandlers.log.postMessage(event.data.__attentive.action);}}, false);";

  WKUserScript *wkUserScript = [[WKUserScript alloc] initWithSource:userScriptWithEventListener injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:FALSE];
  [[wkWebViewConfiguration userContentController] addUserScript:wkUserScript];

  _webView = [[WKWebView alloc] initWithFrame:theView.frame configuration:wkWebViewConfiguration];
  _webView.navigationDelegate = self;

  [_webView loadRequest:request];

  if ([_mode isEqualToString:@"debug"]) {
    [_parentView addSubview:_webView];
  } else {
    _webView.opaque = NO;
    _webView.backgroundColor = [UIColor clearColor];
  }
}

- (void)clearUser {
  [_userIdentity clearUser];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {

  NSString *asyncJs = @"var p = new Promise(resolve => { "
                       "    var timeoutHandle = null;"
                       "    const interval = setInterval(function() {"
                       "        e = document.querySelector('iframe');"
                       "        if(e && e.id === 'attentive_creative') {"
                       "           clearInterval(interval);"
                       "           resolve('SUCCESS');"
                       "           if (timeoutHandle != null) {"
                       "               clearTimeout(timeoutHandle);"
                       "           }"
                       "        }"
                       "    }, 100);"
                       "    timeoutHandle = setTimeout(function() {"
                       "        clearInterval(interval);"
                       "        resolve('TIMED OUT');"
                       "    }, 5000);"
                       "}); "
                       "var status = await p; "
                       "return status;";

  [webView callAsyncJavaScript:asyncJs
                     arguments:nil
                       inFrame:nil
                inContentWorld:WKContentWorld.defaultClientWorld
             completionHandler:^(NSString *status, NSError *error) {
               if (!status) {
                 NSLog(@"No status returned from JS. Not showing WebView.");
                 if (self->_triggerHandler != nil) {
                   self->_triggerHandler(CREATIVE_TRIGGER_STATUS_NOT_OPENED);
                 }
                 return;
               } else if ([status isEqualToString:@"SUCCESS"]) {
                 NSLog(@"Found creative iframe, showing WebView.");
                 if (![self->_mode isEqualToString:@"debug"]) {
                   [self->_parentView addSubview:webView];
                 }
                 if (self->_triggerHandler != nil) {
                   self->_triggerHandler(CREATIVE_TRIGGER_STATUS_OPENED);
                 }
               } else if ([status isEqualToString:@"TIMED OUT"]) {
                 NSLog(@"Creative timed out. Not showing WebView.");
                 if (self->_triggerHandler != nil) {
                   self->_triggerHandler(CREATIVE_TRIGGER_STATUS_NOT_OPENED);
                 }
               } else {
                 NSLog(@"Received unknown status: %@. Not showing WebView", status);
                 if (self->_triggerHandler != nil) {
                   self->_triggerHandler(CREATIVE_TRIGGER_STATUS_NOT_OPENED);
                 }
               }
             }];
}


- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
  if ([message.body isEqualToString:@"CLOSE"]) {
    @try {
      [_webView removeFromSuperview];
      if (self->_triggerHandler != nil) {
        self->_triggerHandler(CREATIVE_TRIGGER_STATUS_CLOSED);
      }
    } @catch (NSException *e) {
      NSLog(@"Exception when closing creative: %@", e.reason);
      if (self->_triggerHandler != nil) {
        self->_triggerHandler(CREATIVE_TRIGGER_STATUS_NOT_CLOSED);
      }
    }
  }
}


- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURL *url = navigationAction.request.URL;
  if ([url.scheme isEqualToString:@"sms"]) {
    [UIApplication.sharedApplication openURL:url];
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  } else if ([[url.scheme lowercaseString] isEqualToString:@"http"] || [[url.scheme lowercaseString] isEqualToString:@"https"]) {
    // If the targetFrame is nil then the link was defined to open in a new tab (two examples of this are the Privacy and Terms links). In this case, open the url in the phone's web browser instead of the webview.
    if ([navigationAction targetFrame] == nil) {
      [UIApplication.sharedApplication openURL:url];
      decisionHandler(WKNavigationActionPolicyCancel);
      return;
    } else {
      decisionHandler(WKNavigationActionPolicyAllow);
    }
  } else {
    decisionHandler(WKNavigationActionPolicyAllow);
  }
}

- (ATTNAPI *)getApi {
  return _api;
}

- (ATTNUserIdentity *)getUserIdentity {
  return _userIdentity;
}

- (void)sendInfoEvent {
  [_api sendEvent:[[ATTNInfoEvent alloc] init] userIdentity:_userIdentity];
}

@end
