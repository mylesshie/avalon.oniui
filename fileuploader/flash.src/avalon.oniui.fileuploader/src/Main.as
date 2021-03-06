package
{
    import flash.display.Loader;
    import flash.display.Sprite;
    import flash.events.DataEvent;
    import flash.events.Event;
    import flash.events.MouseEvent;
    import flash.filters.BevelFilter;
	import flash.geom.Matrix;
    import flash.net.FileFilter;
    import flash.net.FileReference;
	import flash.net.FileReferenceList;
    import flash.net.URLRequest;
	import flash.text.TextFormat;
    import flash.utils.ByteArray;
	import flash.external.*;
	import flash.external.ExternalInterface;
	import mx.graphics.codec.PNGEncoder;
	import mx.utils.Base64Encoder;
	import flash.events.TimerEvent;
	import flash.utils.*;
	import flash.display.Bitmap;
	import flash.display.BitmapData;
	
	/**
	 * ...
	 * @author xuzicn
	 */
		
    public class Main extends Sprite {
		
        private var _fileRef:FileReferenceList;
		
		private var _fileDics:Dictionary;
		private var _fileCacheDics:Dictionary;
		
		// 来自JS的外部参数
		private var _vmId:String;	// VM的ID
		private var _buttonStyle:Object;
		private var _generatePreview:Boolean = false;
		private var _displayPreview:Boolean = false;
		private var _previewGeneratedJSCallbackName:String;
		private var _fileAddedCallbackName:String;
		private var _registed:Boolean = false;
		
		
		public function Main():void {
			var param:Object = this.root.loaderInfo.parameters;
			_vmId = param.vmid;
			
            if (stage) init();
            else addEventListener(Event.ADDED_TO_STAGE, init);
			_fileDics = new Dictionary();
			_fileCacheDics = new Dictionary();
			ExternalInterface.addCallback("readBlob", readBlob);
			
			ExternalInterface.addCallback("cacheFileByMd5", cacheFileByMd5);
			ExternalInterface.addCallback("removeCacheFileByMd5", removeCacheFileByMd5);
		}
		
		public function removeCacheFileByMd5(fileMd5:String):void {
			delete _fileCacheDics[fileMd5];
		}
		public function cacheFileByMd5(fileMd5:String):void {
			var file:FileReference = _fileCacheDics[fileMd5];
			if (file != null) {
				_fileDics[fileMd5] = file;
				delete _fileCacheDics[fileMd5];
			}
		}
		
		private function readBlob(fileMd5:String, offset:Number, size:Number):String {
			var result:String = "";
			try {
				var file:FileReference = _fileDics[fileMd5];
				if (file == null) return "";
				
				jsLog(["****Flash.readBlob. Start to read file chunk. Md5: ", fileMd5, ". offset: ", offset, ". size: ", size]);
				var dataBytes:ByteArray = new ByteArray();
				file.data.position = offset;
				file.data.readBytes(dataBytes, 0, size);
				
				var b:Base64Encoder = new Base64Encoder();
				b.encodeBytes(dataBytes);
				jsLog(["****Flash.readBlob End."]);
				result = b.toString().replace(/[\r\n]/g, "");
			} catch (e:Error) {
				jsLog(["****Flash.readBlob Error. Message: ", e.message]);
			} finally {
				return result;
			}
		}
		private function jsLog(args):void {
			var logs:Array = null;
			if (args is String) {
				logs = [args];
			} else {
				logs = args;
			}
			ExternalInterface.call("avalon.vmodels." + _vmId + ".$runtime.printFlashLog", logs);
		}
		private function init(e:Event = null):void {
            removeEventListener(Event.ADDED_TO_STAGE, init);
            // entry point
			stage.addEventListener(MouseEvent.CLICK, clickHandler);
			
			_fileDics = new Dictionary();
        }
        
		// 生成文件的过滤器
        private function getFilterTypes():Array {
			var jsFilters:Array = ExternalInterface.call("avalon.vmodels." + _vmId + ".getInputAcceptTypes", true);
			var types:Array = new Array(); 
			for (var i:int = 0; i < jsFilters.length; i++) {
				types.push(new FileFilter(jsFilters[i].description as String, jsFilters[i].types as String));
			}
			
            return types;
        }
        
		// 按钮的Click事件
        private function clickHandler(evt:MouseEvent):void {
			// 第一次点击按钮时，向VM注册Flash。不能在初始化时注册，因为VM极有可能还未加载结束。
			if (!_registed) {
				ExternalInterface.call("avalon.vmodels." + _vmId + ".$runtime.registFlash", ExternalInterface.objectID);
				_registed = true;
			}
			
            _fileRef = null;
            
            _fileRef = new FileReferenceList();
            _fileRef.addEventListener(Event.SELECT, selectHandler, false, 0, true);
            
            _fileRef.browse(getFilterTypes());
        }
        
		// 生成文件的Key。以后可以用MD5
		private function getFileKey(file:FileReference):String {
			return file.name+file.type+file.size;
		}
		
		// 文件选择结束后的处理事件
        private function selectHandler(evt:Event):void {
			var files:Array = (evt.currentTarget as FileReferenceList).fileList;
			var count:Number = files.length;
			var file:FileReference;
			
			for(var i:int=0;i<count;i++) {
                file = files[i] as FileReference;
				var fileObj:Object = {
					name: file.name,
					data: null,
					md5:  undefined,
					size: file.size,
					status: null,
					preview: null,
					__flashfile: true,
					__html5file: false,
					chunkAmount: 0,
					blobsProgress: []
				};
				var testFileSizeResult:Object = ExternalInterface.call("avalon.vmodels." + _vmId + ".$runtime.testFileSize", fileObj);
				if (!testFileSizeResult) continue;
				
				var extName:String = file.name.substr(file.name.lastIndexOf("."));	// 文件扩展名
				
				// 获取文件类型的配置参数，包含:
				// 计算MD5时需要的文件包尺寸: md5Size
				// 是否判断为图片文件: isImageFile
				// 是否需要Preview: enablePreview
				// 预览图宽高: previewWidth | previewHeight
				// 默认预览图地址: noPreviewPath
				// 文件尺寸限制：fileSizeLimitation
				var runtimeConfig:Object = ExternalInterface.call("avalon.vmodels." + _vmId + ".getFileConfigByExtName", _vmId, extName);
				fileObj.preview =  runtimeConfig.noPreviewPath;
				
				
				// 加载文件，并将文件考前的数个字节编码，发送给JS。
				var callback:Function = function():void {
					file.removeEventListener(Event.COMPLETE, callback);
					
					var c:ByteArray = new ByteArray();
					file.data.readBytes(c, 0, Math.min(runtimeConfig.md5Size as Number, file.size));
					var b:Base64Encoder = new Base64Encoder();
					b.encodeBytes(c);
					fileObj.md5 = ExternalInterface.call("avalon.vmodels." + _vmId + ".$runtime.md5Bytes", b.toString().replace(/[\r\n]/g, ""));
					_fileCacheDics[fileObj.md5] = file;
					
					if (runtimeConfig.enablePreview && runtimeConfig.isImageFile) {
						generatePreview(file, runtimeConfig, fileObj);
					} else {
						ExternalInterface.call("avalon.vmodels." + _vmId + ".$runtime.addFile", fileObj);
					}
				};
				file.addEventListener(Event.COMPLETE, callback, false, 0, true);
				file.load();
            }
        }
		
		// 生成JPEG格式的预览图。如果配置了Callback的话，发送Base64代码给JS
		private function generatePreview(file:FileReference, runtimeConfig:Object, fileObj:Object):void {
			if (file != null) {
				var imgLoader:Loader = new Loader();
				imgLoader.contentLoaderInfo.addEventListener(Event.COMPLETE, function(event:Event):void {
					var imageWidth:Number = event.currentTarget.loader.content.width;
					var imageHeight:Number = event.currentTarget.loader.content.height;
					var previewHeight:Number = runtimeConfig.previewHeight;
					var previewWidth:Number = runtimeConfig.previewWidth;
					var scale:Number = Math.min(previewHeight / imageHeight, previewWidth / imageWidth);
					var tx:Number = (previewWidth - scale * imageWidth) / 2;
					var ty:Number = (previewHeight - scale * imageHeight) / 2;
					event.currentTarget.loader.content.width = scale * imageWidth;
					event.currentTarget.loader.content.height = scale * imageHeight;
					
					var bitmapData:BitmapData = new BitmapData(previewWidth, previewHeight, false);
					
					bitmapData.draw(imgLoader, new Matrix(1, 0, 0, 1, tx, ty));
					
					var pngEncoder:PNGEncoder = new PNGEncoder();
					
					var c:Base64Encoder = new Base64Encoder();
					
					c.encodeBytes(pngEncoder.encode(bitmapData));
					var code:String =  "data:image/png;base64," + c.toString();
					fileObj.preview = code;
					ExternalInterface.call("avalon.vmodels." + _vmId + ".$runtime.addFile", fileObj);
					
					imgLoader.unload();
					c = null;
					bitmapData = null;
					imgLoader = null;
				});
				imgLoader.loadBytes(file.data);
			}
		}
	}
	
}