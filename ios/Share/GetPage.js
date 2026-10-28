// Safari runs this in the shared page and hands the result to the Share extension.
var GetPage = function () {};
GetPage.prototype.run = function (args) { args.completionFunction({ url: location.href, title: document.title }); };
var ExtensionPreprocessingJS = new GetPage();
