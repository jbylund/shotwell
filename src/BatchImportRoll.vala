// A BatchImportRoll represents important state for a group of imported media.  If this is shared
// among multiple BatchImport objects, the imported media will appear to have been imported all at
// once.
public class BatchImportRoll {
    public ImportID import_id;
    public ViewCollection generated_events = new ViewCollection("BatchImportRoll generated events");
    public BatchImportRoll() {
        this.import_id = ImportID.generate();
    }
}
