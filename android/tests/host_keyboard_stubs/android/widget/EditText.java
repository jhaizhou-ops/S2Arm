package android.widget;
import android.app.Activity;
import android.text.InputFilter;
import android.os.LocaleList;
public class EditText {
    private String text="";
    public EditText(Activity a) {} public void setSingleLine(boolean b) {} public void setInputType(int i) {}
    public void setImeHintLocales(LocaleList l) {} public void setFilters(InputFilter[] f) {} public void setHint(String h) {}
    public void setText(String s) { text=s; } public int length() { return text.length(); } public void setSelection(int n) {}
    public CharSequence getText() { return text; } public void setError(String e) {} public void requestFocus() {}
}
