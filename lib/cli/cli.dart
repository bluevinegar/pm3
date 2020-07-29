import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:colorize/colorize.dart';
import 'package:logging/logging.dart';
import 'package:pm3/util/logging.dart';
import 'package:xml/xml.dart' as xml;

const Map<String, String> emptyParam = {};
enum ContentType { www_form_urlencoded, json, soap }

abstract class BaseClient {
  HttpClient httpClient;
  String stage;
  String country;
  HttpClientRequest request;
  HttpClientResponse response;
  String accessToken = "";
  StringBuffer contents;
  bool isSOAP;
  bool printOnlyLog = false;
  Level logLevel = Level.ALL;

  BaseClient({this.logLevel = Level.ALL});

  String baseURL();
  Future<Map<String, String>> baseParam(String method);

  Future<void> onPrepareRequest(String method,
      {Map<String, dynamic> postParam = emptyParam,
      Map<String, String> queryParam = emptyParam});

  Future<void> onBeforeRequest(String method);

  Future<HttpClientResponse> callSOAP(
    String action,
    String xml, {
    sendAcessToken: true,
  }) async {
    contents = null; //reset
    isSOAP = true;
    String urlStr = baseURL();
    Uri queryURI = Uri.parse(urlStr);
    Map<String, String> queryParam = await baseParam('post')
      ..addAll(queryURI.queryParameters);

    if (sendAcessToken && accessToken != null && accessToken.isNotEmpty) {
      queryParam['access_token'] = accessToken;
    }

    // String jsonData = json.encode(postParam);
    // var postParam = <String, dynamic>{};
    // Map<String, String> postData = formQueryMap(postParam);
    queryURI = Uri(
        scheme: queryURI.scheme,
        host: queryURI.host,
        port: queryURI.port,
        path: queryURI.path,
        queryParameters: queryParam);

    logFine("callSOAP($country) $queryURI ? $queryParam");
    HttpClient cli = HttpClient();
    request = await cli.postUrl(queryURI);
    await onBeforeRequest('post');
    // request.headers.add('SOAPAction', action);

    logFine("callSOAP body: $xml");
    // String
    await request.write(xml);
    response = await request.close();

    logFine("callSOAP response ${response.statusCode}");

    return response;
  }

  Future<HttpClientResponse> callPost(
      String uri, Map<String, dynamic> postParam,
      {sendAcessToken: true,
      postType: ContentType.www_form_urlencoded,
      action: ''}) async {
    contents = null; //reset
    String urlStr = baseURL() + uri;
    Uri queryURI = Uri.parse(urlStr);
    Map<String, String> queryParam = await baseParam('post')
      ..addAll(queryURI.queryParameters);

    if (sendAcessToken && accessToken != null && accessToken.isNotEmpty) {
      queryParam['access_token'] = accessToken;
    }

    // String jsonData = json.encode(postParam);
    await onPrepareRequest('post', postParam: postParam);
    // Map<String, String> postData = formQueryMap(postParam);

    // logFine("LazadaClient($country) uri $queryURI port:${queryURI.port} ");
    queryURI = Uri(
        scheme: queryURI.scheme,
        host: queryURI.host,
        port: queryURI.port,
        path: queryURI.path,
        queryParameters: queryParam);
    logFine("callPost($country) $queryURI ? $queryParam");
    HttpClient cli = HttpClient();
    request = await cli.postUrl(queryURI);
    String postBody;
    if (postType == ContentType.soap) {
      if (action.isEmpty) {
        throw 'Action missing';
      }
      request.headers.add('SOAPAction', action);
    } else if (postType == ContentType.www_form_urlencoded) {
      request.headers
          // .set(HttpHeaders.contentTypeHeader, "application/json; charset=UTF-8");
          .set(HttpHeaders.contentTypeHeader,
              "application/x-www-form-urlencoded; charset=UTF-8");
      postBody = queryMap2QueryString(postParam);
    } else if (postType == ContentType.json) {
      request.headers
        ..set(HttpHeaders.contentTypeHeader, "application/json; charset=UTF-8")
        ..set(HttpHeaders.acceptHeader, "application/json;q=0.9,text/plain");
      postBody = json.encode(postParam);
    }

    await onBeforeRequest('post');
    logFine("callPost: body: $postBody");
    // String
    request.write(postBody);
    response = await request.close();

    logFine("callPost: response ${response.statusCode}");

    return response;
  }

  Future<HttpClientResponse> callGet(String uri, Map<String, String> params,
      {sendAcessToken: true}) async {
    contents = null; //reset
    // int now = new DateTime.now().millisecondsSinceEpoch;
    String urlStr = baseURL() + uri;
    Uri queryURI = Uri.parse(urlStr);
    Map<String, String> bParam = await baseParam('get')
      ..addAll(queryURI.queryParameters);

    Map<String, String> postParam = {};
    postParam.addAll(bParam);
    postParam.addAll(params);
    await onPrepareRequest('get', queryParam: postParam);

    // logInfo("LazadaClient($country) call $urlStr | $postParam");

    // logFine("LazadaClient($country) uri $queryURI port:${queryURI.port} ");
    queryURI = Uri(
        scheme: queryURI.scheme,
        host: queryURI.host,
        port: queryURI.port,
        path: queryURI.path,
        queryParameters: postParam);
    logFine("callGet($country) $queryURI");
    HttpClient cli = HttpClient();
    request = await cli.getUrl(queryURI);
    request.headers
        .set(HttpHeaders.contentTypeHeader, "application/json; charset=UTF-8");
    await onBeforeRequest('post');
    response = await request.close();

    return response;
  }

  Future<bool> responseHasError();
  Future<String> responseErrorMessage();

  Future<dynamic> responseDataAsRaw() async {
    if (response == null) {
      throw "not called yet";
    }
    if (contents != null) {
      return contents.toString();
    }

    final c = Completer();

    await for (var content in response.transform(Utf8Decoder())) {
      contents.write(content);
    }
    c.complete(contents.toString());
    return c.future;
  }

  Future<Map<String, dynamic>> responseDataAsMap() async {
    if (response == null) {
      throw "not called yet";
    }
    if (contents != null) {
      Map<String, dynamic> data = json.decode(contents.toString());
      return data;
    }

    final c = Completer<Map<String, dynamic>>();
    contents = StringBuffer();
    await for (var content in response.transform(Utf8Decoder())) {
      contents.write(content);
    }

    // logFine("responseDataAsMap($country) result: $contents");
    try {
      logger
          .fine("responseDataAsMap($country) decoding: ${contents.toString()}");
      Map<String, dynamic> data = json.decode(contents.toString());
      c.complete(data);
    } catch (e) {
      //unable to parse json
      logFine(
          "responseDataAsMap($country) unable to parse json: ${contents.toString()}");
      c.complete({'raw': contents.toString()});
    }

    return c.future;
  }

  Future<xml.XmlDocument> responseDataAsXML() async {
    if (response == null) {
      throw "not called yet";
    }
    if (contents != null) {
      xml.XmlDocument doc = xml.XmlDocument.parse(contents.toString());
      return doc;
    }

    final c = Completer<xml.XmlDocument>();
    contents = StringBuffer();
    await for (var content in response.transform(Utf8Decoder())) {
      contents.write(content);
    }

    // logFine("LazadaClient.responseDataAsMap($country) result: $contents");
    try {
      logger
          .fine("responseDataAsXML($country) decoding: ${contents.toString()}");

      xml.XmlDocument doc = xml.XmlDocument.parse(contents.toString());
      c.complete(doc);
    } catch (e) {
      //unable to parse json
      logFine(
          "responseDataAsXML($country) unable to parse: ${contents.toString()}");
      c.complete(null);
    }

    return c.future;
  }

  logSevere(msg) {
    if (logLevel > Level.SEVERE) {
      return;
    }
    if (printOnlyLog) {
      print(msg);
      return;
    }
    logger.severe(msg);
  }

  logFine(msg) {
    if (logLevel > Level.FINE) {
      return;
    }
    if (printOnlyLog) {
      Colorize cStr = Colorize(msg)..darkGray();
      print(cStr);
      return;
    }
    logger.fine(msg);
  }

  logFiner(msg) {
    if (logLevel > Level.FINER) {
      return;
    }
    if (printOnlyLog) {
      Colorize cStr = Colorize(msg)..darkGray();
      print(cStr);
      return;
    }
    logger.finer(msg);
  }

  logInfo(msg) {
    if (logLevel > Level.INFO) {
      return;
    }
    if (printOnlyLog) {
      print(msg);
      return;
    }
    logger.info(msg);
  }
} //BaseClient

// convert parameter to query string for both url or post parameter url encoded
String queryMap2QueryString(Map<String, String> data) {
  StringBuffer buf = StringBuffer();
  int index = 0;
  data.forEach((key, value) {
    if (index > 0) {
      buf.write("&");
    }
    buf.write(key);
    buf.write("=");

    index += 1;

    if (value == null) {
      return;
    }

    buf.write(Uri.encodeQueryComponent(value));
  });

  return buf.toString();
}

// converts map<string,dynamic> to map<string,string>
Map<String, String> formQueryMap(Map<String, dynamic> data) {
  // int index = 0;
  var keys = data.keys.toList()..sort((a, b) => a.compareTo(b));
  Map<String, String> res = {};
  keys.forEach((String key) {
    if (key == null) {
      return;
    }

    var value = data[key];
    if (value == null) {
      res[key] = null;
      return;
    }

    // bf.write(Uri.encodeQueryComponent(key));
    if (value != null) {
      if (value is String) {
        if (value.isNotEmpty) {
          res[key] = value;
        }
      } else if (value is List || value is Map) {
        logger.fine("json $key=${json.encode(value)}");
        res[key] = json.encode(value);
      } else {
        res[key] = value.toString();
      }
    }
    // index += 1;
  });

  return res;
}
