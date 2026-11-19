import CoreGraphics
import Foundation

public enum PDFExporter {
    public static func pdf(_ content: ExportContent) throws(ExportError) -> Data {
        let k = 72.0 / 25.4
        let wMM = content.bounds.size.x, hMM = content.bounds.size.y
        guard wMM > 0, hMM > 0 else { throw .nothingToExport }
        var box = CGRect(x: 0, y: 0, width: wMM * k, height: hMM * k)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw .encodingFailed }
        ctx.beginPDFPage(nil)
        // PDF space is y-up points; make it y-down mm with origin at the bounds' top-left.
        ctx.translateBy(x: 0, y: hMM * k)
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: -content.bounds.minX, y: -content.bounds.minY)
        SceneDrawer.draw(content, in: ctx, pixelSize: 0.02)
        ctx.endPDFPage()
        ctx.closePDF()
        guard data.length > 0 else { throw .encodingFailed }
        return data as Data
    }
}
